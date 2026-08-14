module CoPlan
  # "What did I just say, and what was I looking at?" — asked by the voice
  # control after recording, before it posts the comment.
  #
  # Takes either a transcript the browser produced itself or the recorded
  # audio, which is transcribed here. Deliberately a separate request from
  # creating the comment: these are the slow, failure-prone calls, and the
  # comment must not depend on them.
  class DictationsController < ApplicationController
    before_action :set_plan

    # Long enough for a few minutes of Opus, short enough that a stuck
    # recorder can't post a file the size of a video.
    MAX_AUDIO_BYTES = 20.megabytes

    # Nobody speaks faster than this. Conversational English runs about
    # 14 characters a second; auctioneers manage roughly double. A
    # transcript past the ceiling contains words there was no time to
    # say — it was generated, not heard. The slack absorbs very short
    # clips, where rate estimates are mostly rounding.
    MAX_TRANSCRIPT_CHARS_PER_SECOND = 30
    TRANSCRIPT_SLACK_CHARS = 80

    # OpenAI infers the audio format from the filename, so an uploaded
    # blob needs an extension it recognises. Chrome records WebM/Opus,
    # Safari records MP4/AAC.
    AUDIO_EXTENSIONS = {
      "audio/webm" => ".webm", "video/webm" => ".webm",
      "audio/ogg" => ".ogg", "audio/oga" => ".oga",
      "audio/mp4" => ".mp4", "video/mp4" => ".mp4",
      "audio/x-m4a" => ".m4a", "audio/aac" => ".m4a",
      "audio/mpeg" => ".mp3", "audio/mp3" => ".mp3",
      "audio/wav" => ".wav", "audio/x-wav" => ".wav", "audio/wave" => ".wav"
    }.freeze

    def create
      authorize!(@plan, :show?)

      transcript = spoken_text
      result = Comments::InterpretDictation.call(
        excerpt: excerpt,
        # The span has to resolve against the markdown, not against the
        # rendered text the model was shown.
        document: @plan.current_content,
        transcript: transcript,
        # Dictation is conversational in a way typing isn't: the next
        # remark after "it should be main" is "oh, I meant both of them",
        # and without the earlier comment there is no "it" to resolve.
        recent_comments: recent_comments
      )

      # Which copy of the span it is stays the client's job — it can see
      # the rendered document and where in it the person was looking,
      # which is how selection-anchored comments already work.
      # body/anchor_text are the first comment, kept for anything reading
      # the old singular shape; comments is the real answer ("rename both
      # of these" is two placements).
      render json: {
        transcript: transcript,
        body: result.body,
        anchor_text: result.anchor_text,
        comments: result.comments.map { |c| { body: c.body, anchor_text: c.anchor_text } }
      }
    rescue Transcription::Inaudible
      render json: { error: "Didn't hear anything" }, status: :unprocessable_content
    rescue Transcription::Fabricated
      render json: { error: "Didn't catch that — try saying it again" }, status: :unprocessable_content
    rescue Ai::Error => e
      # Only reachable when there was audio and nothing else: interpreting
      # has its own fallbacks, but an untranscribed recording is not a
      # comment, and saying so beats posting silence.
      Rails.logger.warn("[coplan] transcription failed: #{e.message}")
      render json: { error: "Couldn't make out the recording" }, status: :bad_gateway
    end

    module Transcription
      # Silence in, prompt out — see #reject_prompt_echo.
      class Inaudible < StandardError; end
      # More words out than went in — see #reject_fabrication.
      class Fabricated < StandardError; end
    end

    private

    def set_plan
      @plan = Plan.find(params[:plan_id])
    end

    # The browser's own recognition when it has any, otherwise the audio
    # it recorded. Server-side transcription is the better of the two even
    # where both exist — see the voice controller for who sends what.
    def spoken_text
      typed = params[:transcript].to_s
      return typed unless typed.strip.empty?
      return "" if params[:audio].blank?

      transcribe(params[:audio])
    end

    def transcribe(upload)
      raise Ai::Error, "recording is #{upload.size} bytes" if upload.size > MAX_AUDIO_BYTES

      Tempfile.create([ "dictation", extension_for(upload) ], binmode: true) do |file|
        IO.copy_stream(upload.tempfile, file)
        file.flush
        file.rewind
        # What was on screen doubles as a pronunciation hint: it is where
        # the jargon, product names and figures being spoken about live.
        transcript = reject_prompt_echo(Ai.transcribe(file: file, context: excerpt))
        return transcript unless fabricated?(transcript)

        # The transcriber is a chat model with ears, and given an
        # instruction-shaped remark plus a prompt full of context it will
        # sometimes answer instead of transcribing — "add some content
        # about how editing works" once came back as a whole essay,
        # complete with figures lifted from the prompt. The prompt is
        # what it builds the answer from, so the retry goes without one:
        # worse at jargon, but it can only write down what it heard.
        Rails.logger.info(
          "[coplan] dictation rejected as fabricated (#{transcript.length} chars " \
          "in #{duration_ms}ms), retrying without the prompt"
        )
        file.rewind
        transcript = reject_prompt_echo(Ai.transcribe(file: file))
        raise Transcription::Fabricated if fabricated?(transcript)

        transcript
      end
    end

    # More characters than the recording had seconds to hold. Only
    # checkable when the client said how long the take was; without a
    # duration the transcript is taken at its word, as before.
    def fabricated?(transcript)
      return false unless duration_ms.positive?

      transcript.length > (duration_ms / 1000.0) * MAX_TRANSCRIPT_CHARS_PER_SECOND + TRANSCRIPT_SLACK_CHARS
    end

    def duration_ms
      params[:duration_ms].to_i
    end

    # Whisper-family models answer silence by repeating their own prompt.
    # Given two seconds of digital silence and a page about trunk-based
    # development, the "transcript" comes back as the page's first
    # heading — which then reads as a comment nobody wrote, pinned to the
    # very text it was copied from.
    #
    # Anything wholly contained in what we sent is treated as an echo.
    # Reading a sentence off the page aloud trips this too; being told
    # "didn't hear anything" and repeating yourself is a far better
    # outcome than a comment putting words in your mouth.
    def reject_prompt_echo(transcript)
      if normalize(excerpt).include?(normalize(transcript))
        # Logged because this guard has eaten real speech before (a
        # too-late capture posts only the tail of a sentence): the next
        # false rejection should be diagnosable from the log line alone.
        Rails.logger.info("[coplan] dictation rejected as prompt echo: #{transcript.truncate(120).inspect}")
        raise Transcription::Inaudible
      end

      transcript
    end

    def recent_comments
      # kept: a deleted comment's text was removed on purpose, and this
      # context leaves the building — it must not resurface there.
      Comment.kept.joins(:comment_thread)
        .where(comment_thread: { plan_id: @plan.id })
        .order(created_at: :desc).limit(3)
        .includes(:comment_thread)
        .map { |c| { body: c.body_markdown, anchor: c.comment_thread.anchor_text } }
    end

    def normalize(text)
      text.to_s.downcase.gsub(/\s+/, " ").strip
    end

    def extension_for(upload)
      mime = upload.content_type.to_s.split(";").first
      AUDIO_EXTENSIONS[mime] ||
        File.extname(upload.original_filename.to_s).presence ||
        ".webm"
    end

    # Only what the person could actually see. Narrower is better on
    # every axis: the model picks the passage more accurately, has the
    # right context for repairing mis-transcribed jargon, the call is
    # cheaper, and less of the document leaves the building. Falls back
    # to the whole plan when the client can't say what was on screen.
    def excerpt
      visible = params[:excerpt].to_s
      return @plan.current_content.to_s if visible.strip.empty?

      visible.truncate(8_000, omission: "")
    end
  end
end

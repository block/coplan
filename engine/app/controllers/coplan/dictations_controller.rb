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
        transcript: transcript
      )

      # Which copy of the span it is stays the client's job — it can see
      # the rendered document and where in it the person was looking,
      # which is how selection-anchored comments already work.
      render json: {
        transcript: transcript,
        body: result.body,
        anchor_text: result.anchor_text
      }
    rescue Ai::Error => e
      # Only reachable when there was audio and nothing else: interpreting
      # has its own fallbacks, but an untranscribed recording is not a
      # comment, and saying so beats posting silence.
      Rails.logger.warn("[coplan] transcription failed: #{e.message}")
      render json: { error: "Couldn't make out the recording" }, status: :bad_gateway
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
        Ai.transcribe(file: file, context: excerpt)
      end
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

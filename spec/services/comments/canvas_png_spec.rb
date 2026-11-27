require "rails_helper"

RSpec.describe Coplan::Comments::CanvasPng do
  it "keeps the pixel stream from a canvas and drops optional image metadata" do
    png = file_fixture("sample.png").binread
    # tEXt is an ordinary, optional PNG comment.
    text = "Description\0Checkout"
    metadata = [ text.bytesize ].pack("N") + "tEXt" + text + [ Zlib.crc32("tEXt" + text) ].pack("N")
    Tempfile.create([ "canvas", ".png" ], binmode: true) do |file|
      file.write(png.dup.insert(33, metadata))
      file.rewind
      upload = ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: "canvas.png", type: "image/png")
      expect(described_class.new(upload).io.read).to eq(png)
    end
  end
end

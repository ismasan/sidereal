# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'rack/test'
require 'sourced/store/message_codec'

UploadedFileReport = Sidereal::Message.define('uploaded_file_spec.report') do
  attribute :title, Sidereal::Types::String
  attribute :report, Sidereal::Types::UploadedFile.where(type: 'application/pdf')
end

RSpec.describe Sidereal::Types::UploadedFile do
  include Rack::Test::Methods

  # Not valid UTF-8, so a codec that treats the bytes as text breaks the round trip.
  let(:bytes) { "%PDF-1.7\n\xFF\xFE\x00\x01".b }

  let(:tempfile) do
    Tempfile.new(['report', '.pdf'], binmode: true).tap do |f|
      f.write(bytes)
      f.rewind
    end
  end

  # What Rack parses a multipart file field into.
  def rack_upload(type: 'application/pdf')
    {
      filename: 'report.pdf',
      type:,
      name: 'command[payload][report]',
      tempfile:,
      head: "Content-Disposition: form-data; name=\"command[payload][report]\"; filename=\"report.pdf\"\r\n"
    }
  end

  def report_message
    UploadedFileReport.new(payload: { title: 'Q3', report: described_class.new(rack_upload) })
  end

  describe 'from a form' do
    let(:test_app) { Class.new(Sidereal::App) { handle UploadedFileReport } }

    it 'decodes the Rack upload hash into an UploadedFile' do
      result = test_app.forms_codec.resolve('uploaded_file_spec.report', { title: 'Q3', report: rack_upload })

      expect(result).to be_valid
      expect(result.value.report).to be_a(described_class)
      expect(result.value.report.filename).to eq('report.pdf')
      expect(result.value.report.tempfile.read).to eq(bytes)
    end

    it "applies the attribute's own constraints" do
      result = test_app.forms_codec.resolve('uploaded_file_spec.report', { title: 'Q3', report: rack_upload(type: 'image/png') })

      expect(result).not_to be_valid
      expect(result.errors[:report]).to include('application/pdf')
    end

    it 'rejects a field that is not an upload' do
      result = test_app.forms_codec.resolve('uploaded_file_spec.report', { title: 'Q3', report: 'report.pdf' })

      expect(result).not_to be_valid
    end
  end

  describe 'rendering a form' do
    let(:test_app) { Class.new(Sidereal::App) { handle UploadedFileReport } }

    let(:context) do
      Class.new do
        def initialize(forms_codec) = @forms_codec = forms_codec
        def url(addr = nil, *) = addr.to_s
        attr_reader :forms_codec
      end.new(test_app.forms_codec)
    end

    it 'renders a file_field in a multipart form, with no value' do
      html = Sidereal::Components::Command
        .new(UploadedFileReport, enctype: 'multipart/form-data')
        .call(context:) { |f| f.file_field :report, accept: 'application/pdf' }

      expect(html).to include('enctype="multipart/form-data"')
      input = html[/<input[^>]*type="file"[^>]*>/]
      expect(input).to include('name="command[payload][report]"')
      expect(input).to include('accept="application/pdf"')
      expect(input).not_to include('value=')
      expect(html).to include('id="uploaded_file_spec_report-cmd-report-errors"')
    end

    it 'renders a form for a command that already holds an upload' do
      html = Sidereal::Components::Command
        .new(report_message, enctype: 'multipart/form-data')
        .call(context:) do |f|
          f.text_field :title
          f.file_field :report
        end

      expect(html).to include('value="Q3"')
      expect(html[/<input[^>]*type="file"[^>]*>/]).not_to include('value=')
    end
  end

  describe 'through POST /commands' do
    let(:handled) { [] }

    let(:test_app) do
      captured = handled
      Class.new(Sidereal::App) do
        handle UploadedFileReport do |cmd|
          captured << cmd
          status 200
        end
      end
    end

    def app = test_app

    def upload(content_type)
      Rack::Test::UploadedFile.new(tempfile.path, content_type, true, original_filename: 'report.pdf')
    end

    it 'hands the handler an UploadedFile built from the multipart request' do
      post '/commands', command: { type: 'uploaded_file_spec.report', payload: { title: 'Q3', report: upload('application/pdf') } }

      expect(last_response.status).to eq(200)
      file = handled.first.payload.report
      expect(file.filename).to eq('report.pdf')
      expect(file.type).to eq('application/pdf')
      expect(file.tempfile.read).to eq(bytes)
    end

    it 'does not handle an upload that fails its constraints' do
      post '/commands', command: { type: 'uploaded_file_spec.report', payload: { title: 'Q3', report: upload('image/png') } }

      expect(handled).to be_empty
    end
  end

  describe 'over JSON' do
    [Sidereal.message_codec.class, Sourced::Store::MessageCodec].each do |codec_class|
      context "with #{codec_class}" do
        let(:codec) { codec_class.new.compile! }

        it 'carries the file bytes as Base64 and decodes them into a new Tempfile' do
          wire = JSON.parse(JSON.dump(codec.encode(report_message)))
          expect(wire.dig('payload', 'report', 'data')).to eq([bytes].pack('m0'))

          file = codec.decode(wire).payload.report
          expect(file).to be_a(described_class)
          expect(file.tempfile).to be_a(Tempfile)
          expect(file.tempfile.path).not_to eq(tempfile.path)
          expect(file.tempfile.read).to eq(bytes)
          expect(file.filename).to eq('report.pdf')
        end

        it 'leaves the original file where it was being read' do
          tempfile.read(4)
          codec.encode(report_message)

          expect(tempfile.pos).to eq(4)
        end

        it "applies the attribute's own constraints when decoding" do
          wire = JSON.parse(JSON.dump(codec.encode(report_message)))
          wire['payload']['report']['type'] = 'image/png'

          expect { codec.decode(wire) }.to raise_error(Sourced::Message::Codec::DecodeError, /application\/pdf/)
        end
      end
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'
require 'date'

FormsCodecCourse = Sidereal::Message.define('forms_codec_spec.course') do
  attribute :course_name, Sidereal::Types::String.present
  attribute :seats, Sidereal::Types::Integer
  attribute :starts_on, Sidereal::Types::Date
  attribute :published, Sidereal::Types::Boolean
end

FormsCodecPing = Sidereal::Message.define('forms_codec_spec.ping')

# Not exposed via .handle anywhere, so no codec ever compiles it.
FormsCodecPrivate = Sidereal::Message.define('forms_codec_spec.private') do
  attribute :secret, Sidereal::Types::String
end

# A Range is a JSON object with from/to/exclusive, but nothing a form field can
# carry — so this one serializes for transport and is refused at the web boundary.
FormsCodecRanged = Sidereal::Message.define('forms_codec_spec.ranged') do
  attribute :span, Sidereal::Types::Range[Sidereal::Types::Integer]
end

RSpec.describe Sidereal::FormsCodec do
  # An app exposes both commands to the web; the codec compiles from that.
  let(:test_app) do
    Class.new(Sidereal::App) do
      handle FormsCodecCourse, FormsCodecPing
    end
  end

  subject(:codec) { test_app.forms_codec }

  it 'compiles over Plumb::Codec::Forms' do
    expect(codec.format).to be(Plumb::Codec::Forms)
    expect(codec).to be_compiled
  end

  describe '#resolve' do
    # The direction that earns its keep: a form posts Strings and the payload
    # schema is what types them.
    it 'types string params according to the payload schema' do
      result = codec.resolve('forms_codec_spec.course',
                             course_name: 'Ruby 101', seats: '30',
                             starts_on: '2026-09-01', published: 'true')

      expect(result).to be_valid
      expect(result.value.seats).to eq(30)
      expect(result.value.starts_on).to eq(Date.new(2026, 9, 1))
      expect(result.value.published).to be(true)
    end

    it "reads a checkbox's '1' and '0' as booleans" do
      checked = codec.resolve('forms_codec_spec.course', **form_params(published: '1'))
      unchecked = codec.resolve('forms_codec_spec.course', **form_params(published: '0'))

      expect(checked.value.published).to be(true)
      expect(unchecked.value.published).to be(false)
    end

    # Form input is user input, so a failure is a validation result to stream
    # back into the field — not an exception.
    it 'returns a flat attribute => message hash instead of raising' do
      result = codec.resolve('forms_codec_spec.course',
                             **form_params(course_name: '', seats: 'not a number'))

      expect(result).not_to be_valid
      expect(result.errors[:course_name]).to eq('must be present')
      expect(result.errors[:seats]).to include('Must match')
      # flat, so App#patch_command_errors can address each field by name
      expect(result.errors.keys).to contain_exactly(:course_name, :seats)
    end

    it 'accepts nil params for a command declaring no payload' do
      result = codec.resolve('forms_codec_spec.ping', nil)

      expect(result).to be_valid
      expect(result.value).to be_nil
    end

    it 'raises for a type that was never exposed to the web' do
      expect {
        codec.resolve('forms_codec_spec.private', secret: 'x')
      }.to raise_error(described_class::UnregisteredTypeError, /forms_codec_spec\.private/)
    end
  end

  describe '#encode_payload' do
    let(:values) do
      { course_name: 'Ruby 101', seats: 30, starts_on: Date.new(2026, 9, 1), published: false }
    end

    it 'renders each declared type as the string an input carries' do
      encoded = codec.encode_payload(FormsCodecCourse.new(payload: values)).value

      expect(encoded).to eq(
        course_name: 'Ruby 101', seats: '30', starts_on: '2026-09-01', published: 'false'
      )
    end

    it 'round-trips back to the declared types' do
      encoded = codec.encode_payload(FormsCodecCourse.new(payload: values)).value

      expect(codec.resolve('forms_codec_spec.course', **encoded).value.to_h).to eq(values)
    end

    # A form is rendered from whatever the command holds so far, so the encode
    # pass has to be per-key rather than all-or-nothing: #parse would reject both
    # of these outright.
    it 'yields the attributes that are set and leaves out the rest' do
      partial = FormsCodecCourse.new(payload: { course_name: 'Ruby 101', seats: 30 })

      expect(codec.encode_payload(partial).value).to eq(course_name: 'Ruby 101', seats: '30')
    end

    it 'yields an empty hash for a blank command, so no field renders a value' do
      expect(codec.encode_payload(FormsCodecCourse.new).value).to eq({})
    end

    # Not a hash of attributes: a nil payload encodes to the empty string the
    # Forms codec renders nil as. Such a command has no fields to render.
    it 'yields no attribute hash for a command declaring no payload' do
      expect(codec.encode_payload(FormsCodecPing.new).value).not_to be_a(Hash)
    end

    it 'does not raise on a payload it cannot fully encode' do
      expect { codec.encode_payload(FormsCodecCourse.new) }.not_to raise_error
    end

    it 'raises for a type that was never exposed to the web' do
      expect {
        codec.encode_payload(FormsCodecPrivate.new(payload: { secret: 'x' }))
      }.to raise_error(described_class::UnregisteredTypeError, /forms_codec_spec\.private/)
    end
  end

  describe 'compiling at .handle time' do
    it 'knows only the commands the app exposed' do
      expect(codec).to be_registered('forms_codec_spec.course')
      expect(codec).not_to be_registered('forms_codec_spec.private')
    end

    it 'picks up a command exposed after the codec first compiled' do
      app = Class.new(Sidereal::App) { handle FormsCodecPing }
      expect(app.forms_codec).not_to be_registered('forms_codec_spec.course')

      app.handle FormsCodecCourse

      expect(app.forms_codec).to be_registered('forms_codec_spec.course')
      expect(app.forms_codec.resolve('forms_codec_spec.course', **form_params)).to be_valid
    end

    it 'gives a subclass a working codec for the commands it inherited' do
      parent = Class.new(Sidereal::App) { handle FormsCodecCourse }
      child = Class.new(parent)

      expect(child.forms_codec).not_to be(parent.forms_codec)
      expect(child.forms_codec.resolve('forms_codec_spec.course', **form_params)).to be_valid
    end

    # The boot check: exposing a command to the web is the claim that a form can
    # carry its payload, so that is where an unrepresentable attribute fails.
    # A Range is representable in JSON (as a from/to/exclusive object) but not
    # in a form field, so it is compiled by the transport codec and refused here.
    it 'raises when a payload attribute cannot be represented as form input' do
      expect {
        Class.new(Sidereal::App) { handle FormsCodecRanged }
      }.to raise_error(Plumb::TypeError, /span/)
    end
  end

  # A full set of valid form params, with any overrides applied.
  def form_params(overrides = {})
    { course_name: 'Ruby 101', seats: '30', starts_on: '2026-09-01', published: 'true' }.merge(overrides)
  end
end

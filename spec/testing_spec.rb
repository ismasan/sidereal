# frozen_string_literal: true

require 'spec_helper'
require 'sidereal/testing'

HarnessTestSend = Sidereal::Message.define('harness_test.send') do
  attribute :text, Sidereal::Types::String.present
  attribute :count, Sidereal::Types::Integer.nullable
end
HarnessTestStore = Sidereal::Message.define('harness_test.store') do
  attribute :text, Sidereal::Types::String
  attribute :author, Sidereal::Types::String.nullable
end
HarnessTestClear = Sidereal::Message.define('harness_test.clear')

RSpec.describe Sidereal::Testing::Harness do
  subject(:harness) { described_class.new(component) }

  let(:component) do
    Class.new(Sidereal::Components::BaseComponent) do
      handle HarnessTestSend do |cmd|
        reject(text: 'is rude') if cmd.payload.text == 'rude'

        session['sent'] = cmd.payload.text
        dispatch HarnessTestStore, text: cmd.payload.text, author: session['user']
        browser.patch_elements %(<div id="last">#{cmd.payload.text}</div>)
        browser.patch_signals(count: cmd.payload.count)
      end

      handle HarnessTestClear
    end
  end

  it 'handles a command in an app with the component installed, and returns what it sent the browser' do
    result = harness.handle(HarnessTestSend, { text: 'hi', count: 2 })

    expect(result.status).to eq(200)
    expect(result).not_to be_rejected
    expect(result.elements).to eq(['<div id="last">hi</div>'])
    expect(result.signals).to eq('count' => 2)
    expect(result.events.map(&:type)).to eq(%w[datastar-patch-elements datastar-patch-signals])
  end

  it 'records the commands the handler dispatches, correlated to the one it handled, without storing them' do
    Sidereal.config.build!
    expect(Sidereal.store).not_to receive(:append)

    result = harness.handle(HarnessTestSend.new(payload: { text: 'hi' }), session: { 'user' => 'ada' })

    expect(result.command).to be_a(HarnessTestSend)
    expect(result.command.payload.text).to eq('hi')
    expect(result.dispatched.map(&:class)).to eq([HarnessTestStore])
    expect(result.dispatched.first.payload.to_h).to eq(text: 'hi', author: 'ada')
    expect(result.dispatched.first.correlation_id).to eq(result.command.correlation_id)
    expect(result.dispatched.first.causation_id).to eq(result.command.id)
  end

  it 'returns the session, as the handler left it' do
    result = harness.handle(HarnessTestSend, { text: 'hi' }, session: { 'user' => 'ada' })

    expect(result.session.to_h).to include('user' => 'ada', 'sent' => 'hi')
  end

  it 'returns the errors the handler rejects the command with' do
    result = harness.handle(HarnessTestSend, { text: 'rude' })

    expect(result).to be_rejected
    expect(result.errors).to eq(text: 'is rude')
    expect(result.dispatched).to be_empty
  end

  it "validates a form's strings as the app does, and rejects invalid ones" do
    result = harness.handle(HarnessTestSend, form: { 'text' => '', 'count' => 'many' })

    expect(result).to be_rejected
    expect(result.errors.keys).to contain_exactly(:text, :count)
  end

  it "decodes a form's strings into the payload's types" do
    result = harness.handle(HarnessTestSend, form: { 'text' => 'hi', 'count' => '3' })

    expect(result.signals).to eq('count' => 3)
  end

  it 'runs the default handler for a command declared without a block, which dispatches it' do
    result = harness.handle(HarnessTestClear)

    expect(result.status).to eq(200)
    expect(result.dispatched.map(&:class)).to eq([HarnessTestClear])
  end

  it "handles commands like a given app, with its before_command, without changing it" do
    base = Class.new(Sidereal::App) do
      before_command { |cmd| cmd.with_payload(text: cmd.payload.text.upcase) }
    end

    result = described_class.new(component, app: base).handle(HarnessTestSend, { text: 'hi' })

    expect(result.elements).to eq(['<div id="last">HI</div>'])
    expect(result.command.payload.text).to eq('HI')
    expect(base.handled_commands).to be_empty
  end

  it "merges the session given into the one an app's cookie session loads, with a secret or a lambda" do
    ['c' * 64, -> { 'c' * 64 }].each do |secret|
      base = Class.new(Sidereal::App) { session secret: }

      result = described_class.new(component, app: base).handle(HarnessTestSend, { text: 'hi' }, session: { 'user' => 'ada' })

      expect(result.dispatched.first.payload.author).to eq('ada')
      expect(result.session.to_h).to include('user' => 'ada', 'sent' => 'hi')
      expect(result.headers['set-cookie']).to include('rack.session=')
    end
  end

  it 'gives each command a result of its own' do
    harness.handle(HarnessTestSend, { text: 'one' })
    result = harness.handle(HarnessTestSend, { text: 'rude' })

    expect(result.dispatched).to be_empty
    expect(harness.handle(HarnessTestSend, { text: 'two' }).errors).to be_nil
  end
end

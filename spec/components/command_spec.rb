# frozen_string_literal: true

require 'spec_helper'

CommandSpecAddItem = Sidereal::Message.define('command_spec.add_item') do
  attribute :title, Sidereal::Types::String.present
end

RSpec.describe Sidereal::Components::Command do
  # The component calls context.url(@href) while rendering, so give it a
  # minimal context that echoes the address back.
  let(:context) do
    Class.new do
      def url(addr = nil, *) = addr.to_s
    end.new
  end

  def render(*args, &block)
    block ||= proc { |f| f.text_field :title }
    described_class.new(*args).call(context:, &block)
  end

  it 'derives a deterministic id prefix from the command type' do
    html = render(CommandSpecAddItem)
    # type 'command_spec.add_item' sanitized + default key 'cmd'
    expect(html).to include('name="command[_cid]" value="command_spec_add_item-cmd"')
    expect(html).to include('id="command_spec_add_item-cmd-title"')
    expect(html).to include('id="command_spec_add_item-cmd-title-wrapper"')
    expect(html).to include('id="command_spec_add_item-cmd-title-errors"')
  end

  it 'sanitizes dots out of generated ids (the dotted type stays in command[type])' do
    html = render(CommandSpecAddItem)
    ids = html.scan(/id="([^"]*)"/).flatten
    expect(ids).not_to be_empty
    expect(ids).to all(satisfy { |id| !id.include?('.') })
    # the real dotted type is still submitted as the command type
    expect(html).to include('name="command[type]" value="command_spec.add_item"')
  end

  it 'produces identical ids across separate renders of the same form' do
    expect(render(CommandSpecAddItem)).to eq(render(CommandSpecAddItem))
  end

  it 'uses :key to disambiguate multiple instances of the same command type' do
    one = render(CommandSpecAddItem, key: 42)
    two = render(CommandSpecAddItem, key: 99)

    expect(one).to include('id="command_spec_add_item-42-title"')
    expect(two).to include('id="command_spec_add_item-99-title"')
    expect(one).not_to eq(two)
  end

  it 'does not leak :key as an attribute on the form element' do
    html = render(CommandSpecAddItem, key: 42)
    expect(html).to match(/<form[^>]*>/)
    expect(html[/<form[^>]*>/]).not_to include('key=')
  end
end

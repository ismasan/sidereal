# frozen_string_literal: true

require 'spec_helper'

PageTestItemAdded = Sidereal::Message.define('page_test.item_added') do
  attribute :title, Sidereal::Types::String
end

PageTestNotification = Sidereal::Message.define('page_test.notification') do
  attribute :text, Sidereal::Types::String
end

class FakeSSE
  attr_reader :patches, :signals

  def initialize(signals = {})
    @signals = signals
    @patches = []
  end

  def patch_elements(component)
    @patches << component
  end
end

RSpec.describe Sidereal::Page do
  describe '.path' do
    it 'sets and returns the path' do
      page_class = Class.new(Sidereal::Page) { path '/todos' }
      expect(page_class.path).to eq('/todos')
    end

    it 'returns nil when no path is set' do
      page_class = Class.new(Sidereal::Page)
      expect(page_class.path).to be_nil
    end
  end

  describe '.page_key' do
    it 'returns the path when set' do
      page_class = Class.new(Sidereal::Page) { path '/items' }
      expect(page_class.page_key).to eq('/items')
    end

    it 'falls back to class name when no path is set' do
      page_class = Class.new(Sidereal::Page)
      expect(page_class.page_key).to eq(page_class.name)
    end
  end

  describe '.register' do
    it 'registers a page class by its page_key' do
      page_class = Class.new(Sidereal::Page) { path '/registered' }
      Sidereal::Page.register(page_class)
      expect(Sidereal::Page.registry['/registered']).to eq(page_class)
    end
  end

  describe '.on' do
    it 'registers a reaction handler for a message class' do
      page_class = Class.new(Sidereal::Page) do
        on PageTestItemAdded do |evt|
          # handle
        end
      end

      expect(page_class.reactions).to have_key(PageTestItemAdded)
    end

    it 'inherits reactions from the parent page' do
      parent = Class.new(Sidereal::Page) do
        on PageTestItemAdded do |evt|
        end
      end

      child = Class.new(parent) do
        on PageTestNotification do |evt|
        end
      end

      expect(child.reactions.keys).to contain_exactly(PageTestItemAdded, PageTestNotification)
      expect(parent.reactions.keys).to eq([PageTestItemAdded])
    end

    it 'does not share reactions between page subclasses' do
      page_a = Class.new(Sidereal::Page) do
        on PageTestItemAdded do |evt|
        end
      end

      page_b = Class.new(Sidereal::Page) do
        on PageTestNotification do |evt|
        end
      end

      expect(page_a.reactions.keys).to eq([PageTestItemAdded])
      expect(page_b.reactions.keys).to eq([PageTestNotification])
    end
  end

  describe 'rendering' do
    it 'renders view_template as HTML' do
      page_class = Class.new(Sidereal::Page) do
        def initialize(items: [])
          @items = items
        end

        def view_template
          ul do
            @items.each { |item| li { item } }
          end
        end
      end

      page = page_class.new(items: ['Buy milk', 'Walk dog'])
      html = page.call
      expect(html).to include('<li>Buy milk</li>')
      expect(html).to include('<li>Walk dog</li>')
    end

    it 'renders an empty page' do
      page_class = Class.new(Sidereal::Page) do
        def view_template
          div { 'Empty' }
        end
      end

      html = page_class.new.call
      expect(html).to include('<div>Empty</div>')
    end
  end

  describe 'PageContext reactions' do
    let(:page_context_class) { Sidereal::Page::PageContext }

    let(:page_class) do
      Class.new(Sidereal::Page) do
        path '/reactive'

        def self.load(_params, _ctx)
          new
        end

        def view_template
          div { 'loaded' }
        end

        on PageTestItemAdded do |evt|
          browser.patch_elements load(params)
        end
      end
    end

    it 'reacts to registered events by patching elements' do
      sse = FakeSSE.new('page_key' => '/reactive', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class)

      evt = PageTestItemAdded.new(payload: { title: 'hello' })
      page_context.react(evt)

      expect(sse.patches.size).to eq(1)
    end

    it 'ignores events without a registered handler' do
      sse = FakeSSE.new('page_key' => '/reactive', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class)

      evt = PageTestNotification.new(payload: { text: 'hi' })
      page_context.react(evt)

      expect(sse.patches).to be_empty
    end

    it 'provides access to params from signals' do
      sse = FakeSSE.new('page_key' => '/reactive', 'params' => { 'id' => '42' })
      page_context = page_context_class.new(sse, nil, page_class)

      evt = PageTestItemAdded.new(payload: { title: 'test' })
      page_context.react(evt)

      expect(sse.patches.size).to eq(1)
    end
  end
end

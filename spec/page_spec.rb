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

  def patch_elements(component, options = {})
    @patches << { component: component, options: options }
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

    it 'registers the same reaction handler for multiple message classes' do
      page_class = Class.new(Sidereal::Page) do
        on PageTestItemAdded, PageTestNotification do |evt|
          # handle
        end
      end

      expect(page_class.reactions.keys).to include(PageTestItemAdded, PageTestNotification)
      expect(page_class.reactions[PageTestItemAdded]).to eq(page_class.reactions[PageTestNotification])
    end

    it 'registers the message type to reload on when given no block' do
      page_class = Class.new(Sidereal::Page) do
        on PageTestItemAdded, PageTestNotification
      end

      expect(page_class.correlation_types).to include(PageTestItemAdded.type, PageTestNotification.type)
      expect(page_class.reactions).not_to have_key(PageTestItemAdded)
    end

    it 'requires at least one message class' do
      expect do
        Class.new(Sidereal::Page) do
          on do |evt|
            # handle
          end
        end
      end.to raise_error(ArgumentError, 'at least one message class is required')
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

      expect(child.reactions.keys).to include(PageTestItemAdded, PageTestNotification)
      expect(parent.reactions.keys).to include(PageTestItemAdded)
      expect(parent.reactions.keys).not_to include(PageTestNotification)
    end

    it 'inherits correlation types from the parent page' do
      parent = Class.new(Sidereal::Page) do
        on PageTestItemAdded
      end
      child = Class.new(parent) do
        on PageTestNotification
      end

      expect(child.correlation_types).to include(PageTestItemAdded.type, PageTestNotification.type)
      expect(parent.correlation_types).to include(PageTestItemAdded.type)
      expect(parent.correlation_types).not_to include(PageTestNotification.type)
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

      expect(page_a.reactions.keys).to include(PageTestItemAdded)
      expect(page_a.reactions.keys).not_to include(PageTestNotification)
      expect(page_b.reactions.keys).to include(PageTestNotification)
      expect(page_b.reactions.keys).not_to include(PageTestItemAdded)
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

  describe 'rendered command forms' do
    # A command form encodes its values through the codec of the app that
    # exposed the command, reached as +context.forms_codec+.
    let(:app) { Class.new(Sidereal::App) { handle PageTestItemAdded, PageTestNotification } }
    let(:context) do
      Class.new do
        def initialize(forms_codec) = @forms_codec = forms_codec
        def url(addr = nil, *) = addr.to_s
        attr_reader :forms_codec
      end.new(app.forms_codec)
    end

    let(:item_form) do
      Class.new(Sidereal::Components::BaseComponent) do
        def view_template
          command PageTestItemAdded do |f|
            f.text_field :title
          end
        end
      end
    end

    it 'register the command type on the page being rendered' do
      page = Class.new(Sidereal::Page) do
        def view_template
          command PageTestNotification do |f|
            f.text_field :text
          end
        end
      end

      expect(page.correlation_types).to be_empty
      page.new.call(context:)

      expect(page.correlation_types).to include(PageTestNotification.type)
    end

    it 'register from any depth of the component tree' do
      form = item_form
      page = Class.new(Sidereal::Page) do
        define_method(:view_template) { div { render form.new } }
      end

      page.new.call(context:)

      expect(page.correlation_types).to include(PageTestItemAdded.type)
    end

    it 'do not leak the rendering page past the render' do
      page = Class.new(Sidereal::Page) do
        def view_template = div { 'plain' }
      end

      page.new.call(context:)

      expect(Sidereal::Page.rendering).to be_nil
    end

    it 'register nothing when rendered outside a page' do
      html = item_form.new.call(context:)

      expect(html).to include('page_test.item_added')
      expect(Sidereal::Page.correlation_types).to be_empty
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

    it 'reloads and patches the page when registered without a block' do
      loaded_with = :unset
      blockless_page = Class.new(Sidereal::Page) do
        path '/blockless'

        def initialize(params)
          @params = params
        end

        def view_template
          div { 'reloaded' }
        end

        on PageTestItemAdded
      end
      blockless_page.define_singleton_method(:load) do |params, _ctx|
        loaded_with = params
        new(params)
      end

      sse = FakeSSE.new('page_key' => '/blockless', 'params' => { 'id' => '7' })
      page_context = page_context_class.new(sse, nil, blockless_page)

      page_context.react(PageTestItemAdded.new(payload: { title: 'hello' }))

      expect(loaded_with).to eq({ id: '7' })
      expect(sse.patches.size).to eq(1)
      expect(sse.patches.first[:component]).to be_a(blockless_page)
    end

    it 'reloads on a message produced as a consequence of a registered type' do
      page = Class.new(Sidereal::Page) do
        path '/consequence'
        def self.load(_params, _ctx) = new
        def view_template = div { 'reloaded' }
        on PageTestItemAdded
      end

      sse = FakeSSE.new('page_key' => '/consequence', 'params' => {})
      page_context = page_context_class.new(sse, nil, page)

      cmd = PageTestItemAdded.new(payload: { title: 'hello' })
      evt = cmd.correlate(PageTestNotification.new(payload: { text: 'added' }))
      page_context.react(evt)

      expect(evt.correlation_type).to eq(PageTestItemAdded.type)
      expect(sse.patches.size).to eq(1)
      expect(sse.patches.first[:component]).to be_a(page)
    end

    it 'reloads on a registered type that arrives with another chain root' do
      page = Class.new(Sidereal::Page) do
        path '/own-type'
        def self.load(_params, _ctx) = new
        def view_template = div { 'reloaded' }
        on PageTestNotification
      end

      sse = FakeSSE.new('page_key' => '/own-type', 'params' => {})
      page_context = page_context_class.new(sse, nil, page)

      cmd = PageTestItemAdded.new(payload: { title: 'hello' })
      evt = cmd.correlate(PageTestNotification.new(payload: { text: 'added' }))
      page_context.react(evt)

      expect(evt.correlation_type).to eq(PageTestItemAdded.type)
      expect(sse.patches.size).to eq(1)
    end

    it 'prefers the handler for the exact message class over a correlation match' do
      handled = []
      page = Class.new(Sidereal::Page) do
        path '/precedence'
        def self.load(_params, _ctx) = new
        def view_template = div { 'reloaded' }
        on PageTestItemAdded
        on PageTestNotification do |evt|
          handled << evt
        end
      end

      sse = FakeSSE.new('page_key' => '/precedence', 'params' => {})
      page_context = page_context_class.new(sse, nil, page)

      cmd = PageTestItemAdded.new(payload: { title: 'hello' })
      evt = cmd.correlate(PageTestNotification.new(payload: { text: 'added' }))
      page_context.react(evt)

      expect(handled).to eq([evt])
      expect(sse.patches).to be_empty
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

    it 'symbolizes param keys from signals' do
      captured_params = nil
      page_with_params = Class.new(Sidereal::Page) do
        path '/with-params'
        on PageTestItemAdded do |evt|
          captured_params = params
        end
      end

      sse = FakeSSE.new('page_key' => '/with-params', 'params' => { 'id' => '42', 'filter' => 'active' })
      page_context = page_context_class.new(sse, nil, page_with_params)

      page_context.react(PageTestItemAdded.new(payload: { title: 'test' }))

      expect(captured_params).to eq({ id: '42', filter: 'active' })
    end

    it 'provides an empty params hash when signal params are missing' do
      captured_params = :unset
      page_with_missing_params = Class.new(Sidereal::Page) do
        path '/missing-params'
        on PageTestItemAdded do |_evt|
          captured_params = params
        end
      end

      sse = FakeSSE.new('page_key' => '/missing-params')
      page_context = page_context_class.new(sse, nil, page_with_missing_params)

      page_context.react(PageTestItemAdded.new(payload: { title: 'test' }))

      expect(captured_params).to eq({})
    end
  end

  describe '.subscribe' do
    it 'passes an empty params hash to load when signal params are missing' do
      captured_params = :unset
      page_class = Class.new(Sidereal::Page) do
        path '/subscribe-missing-params'

        define_singleton_method(:load) do |params, _ctx|
          captured_params = params
          new
        end

        def view_template
          div { 'loaded' }
        end
      end

      Sidereal::Page.register(page_class)
      sse = FakeSSE.new('page_key' => '/subscribe-missing-params')
      channel = double(:channel, start: nil)

      Sidereal::Page.subscribe(channel, sse, nil)

      expect(captured_params).to eq({})
    end

    it 'symbolizes signal params before passing them to load' do
      captured_params = nil
      page_class = Class.new(Sidereal::Page) do
        path '/subscribe-params'

        define_singleton_method(:load) do |params, _ctx|
          captured_params = params
          new
        end

        def view_template
          div { 'loaded' }
        end
      end

      Sidereal::Page.register(page_class)
      sse = FakeSSE.new('page_key' => '/subscribe-params', 'params' => { 'id' => '42' })
      channel = double(:channel, start: nil)

      Sidereal::Page.subscribe(channel, sse, nil)

      expect(captured_params).to eq({ id: '42' })
    end
  end

  describe 'default system notification reactions' do
    let(:page_context_class) { Sidereal::Page::PageContext }

    let(:page_class) do
      Class.new(Sidereal::Page) do
        path '/sys'
        def self.load(_p, _c) = new
        def view_template = div { 'x' }
      end
    end

    def build_retry_evt
      Sidereal::System::NotifyRetry.new(payload: {
        command_type: 'todos.add',
        command_id: SecureRandom.uuid,
        command_payload: { title: 'x' },
        retry_count: 2,
        retry_at: Time.now.iso8601(6),
        error_class: 'RuntimeError',
        error_message: 'boom',
        backtrace: ['a.rb:1', 'b.rb:2']
      })
    end

    def build_failure_evt
      Sidereal::System::NotifyFailure.new(payload: {
        command_type: 'todos.add',
        command_id: SecureRandom.uuid,
        command_payload: { title: 'x' },
        retry_count: 5,
        error_class: 'RuntimeError',
        error_message: 'permanent',
        backtrace: []
      })
    end

    it 'subclasses inherit reactions for both system commands' do
      expect(page_class.reactions).to have_key(Sidereal::System::NotifyRetry)
      expect(page_class.reactions).to have_key(Sidereal::System::NotifyFailure)
    end

    it 'reacts to NotifyRetry by patching SystemNotifyRetry to body, prepend mode' do
      sse = FakeSSE.new('page_key' => '/sys', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class)

      page_context.react(build_retry_evt)

      expect(sse.patches.size).to eq(1)
      patch = sse.patches.first
      expect(patch[:component]).to be_a(Sidereal::Components::SystemNotifyRetry)
      expect(patch[:options]).to eq(mode: 'prepend', selector: '#sidereal-sysnotify-stack')
    end

    it 'reacts to NotifyFailure by patching SystemNotifyFailure to body, prepend mode' do
      sse = FakeSSE.new('page_key' => '/sys', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class)

      page_context.react(build_failure_evt)

      expect(sse.patches.size).to eq(1)
      patch = sse.patches.first
      expect(patch[:component]).to be_a(Sidereal::Components::SystemNotifyFailure)
      expect(patch[:options]).to eq(mode: 'prepend', selector: '#sidereal-sysnotify-stack')
    end

    it 'allows a user page to override the default NotifyFailure reaction' do
      called_with = nil
      override = Class.new(Sidereal::Page) do
        path '/sys-override'
        def self.load(_p, _c) = new
        def view_template = div { 'x' }
        on(Sidereal::System::NotifyFailure) { |evt| called_with = evt }
      end

      sse = FakeSSE.new('page_key' => '/sys-override', 'params' => {})
      page_context = page_context_class.new(sse, nil, override)

      evt = build_failure_evt
      page_context.react(evt)

      expect(called_with).to eq(evt)
      # The default patch_elements call should NOT have run.
      expect(sse.patches).to be_empty
    end
  end
end

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

  describe '.query_schema' do
    it 'is empty for a page with no path segments and no schema' do
      page_class = Class.new(Sidereal::Page) { path '/todos' }

      expect(page_class.query_schema._schema).to be_empty
      expect(page_class.parse_params({ q: 'x' }).value).to eq({})
    end

    it 'types path segments as Strings by default' do
      page_class = Class.new(Sidereal::Page) { path '/accounts/:account_id/expenses/:id' }

      expect(page_class.query_schema.inspect).to eq('Hash[account_id: Sidereal::Types::String, id: Sidereal::Types::String]')
      expect(page_class.parse_params({ account_id: 'a', id: 'b', q: 'x' }).value).to eq({ account_id: 'a', id: 'b' })
    end

    it 'decodes declared params from their String form and drops undeclared ones' do
      page_class = Class.new(Sidereal::Page) do
        path '/accounts/:id/expenses'
        query_schema(
          id: Sidereal::Types::UUID::V4,
          from?: Sidereal::Types::Date,
          archived?: Sidereal::Types::Boolean
        )
      end
      id = SecureRandom.uuid

      result = page_class.parse_params({ 'id' => id, 'from' => '2026-11-01', 'archived' => 'true', 'other' => 'x' })

      expect(result).to be_valid
      expect(result.value).to eq({ id:, from: Date.new(2026, 11, 1), archived: true })
    end

    it 'leaves optional params out when absent' do
      page_class = Class.new(Sidereal::Page) do
        path '/expenses'
        query_schema(from?: Sidereal::Types::Date)
      end

      expect(page_class.parse_params(nil).value).to eq({})
    end

    it 'keeps undeclared path segments as Strings alongside the declared schema' do
      page_class = Class.new(Sidereal::Page) do
        path '/accounts/:id/expenses'
        query_schema(from?: Sidereal::Types::Date)
      end

      expect(page_class.parse_params({ id: '1', from: '2026-11-01' }).value).to eq({ id: '1', from: Date.new(2026, 11, 1) })
    end

    it 'picks up path segments declared after the schema' do
      page_class = Class.new(Sidereal::Page) do
        query_schema(page?: Sidereal::Types::Integer)
        path '/items/:id'
      end

      expect(page_class.parse_params({ id: '1', page: '2' }).value).to eq({ id: '1', page: 2 })
    end

    it 'accepts a ready Hash schema' do
      page_class = Class.new(Sidereal::Page) do
        path '/items/:id'
        query_schema Sidereal::Types::Hash[id: Sidereal::Types::Integer]
      end

      expect(page_class.parse_params({ id: '3' }).value).to eq({ id: 3 })
    end

    it 'reports invalid params as errors keyed by param' do
      page_class = Class.new(Sidereal::Page) do
        path '/items/:id'
        query_schema(id: Sidereal::Types::Integer, from?: Sidereal::Types::Date)
      end

      result = page_class.parse_params({ id: 'nope', from: 'bad' })

      expect(result).not_to be_valid
      expect(result.errors.keys).to contain_exactly(:id, :from)
    end

    it 'merges a subclass schema into its superclass schema' do
      parent = Class.new(Sidereal::Page) { query_schema(from: Sidereal::Types::Date) }
      child = Class.new(parent) { query_schema(id: Sidereal::Types::UUID::V4) }

      expect(child.query_schema.inspect).to eq('Hash[from: Sidereal::Types::Date, id: Sidereal::Types::UUID::V4]')
      expect(parent.query_schema.inspect).to eq('Hash[from: Sidereal::Types::Date]')
    end

    it 'inherits the superclass schema, merged with the subclass path segments' do
      parent = Class.new(Sidereal::Page) { query_schema(from?: Sidereal::Types::Date) }
      child = Class.new(parent) { path '/items/:id' }

      expect(child.parse_params({ id: '1', from: '2026-11-01' }).value).to eq({ id: '1', from: Date.new(2026, 11, 1) })
    end

    it 'lets a subclass redeclare an inherited field' do
      parent = Class.new(Sidereal::Page) { query_schema(page: Sidereal::Types::String) }
      child = Class.new(parent) { query_schema(page: Sidereal::Types::Integer) }

      expect(child.parse_params({ page: '2' }).value).to eq({ page: 2 })
    end

    it 'merges repeated declarations in one class' do
      page_class = Class.new(Sidereal::Page) do
        query_schema(from?: Sidereal::Types::Date)
        query_schema(page?: Sidereal::Types::Integer)
      end

      expect(page_class.parse_params({ from: '2026-11-01', page: '2' }).value).to eq({ from: Date.new(2026, 11, 1), page: 2 })
    end

    it 'raises at definition for a type the Forms codec cannot carry' do
      expect {
        Class.new(Sidereal::Page) { query_schema(at: Class.new) }
      }.to raise_error(Plumb::TypeError)
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

  describe '#channel_names' do
    it 'subscribes to the system channel by default' do
      page_class = Class.new(Sidereal::Page) { path '/default-channels' }
      expect(page_class.new.channel_names).to eq(['system'])
    end
  end

  describe '.stream_token and .resolve_stream' do
    let(:page_class) do
      Class.new(Sidereal::Page) do
        path '/orders/:id'
        query_schema(id: Sidereal::Types::Integer)

        def initialize(account_id: 'a1') = @account_id = account_id
        def channel_names = ['orders.>', "accounts.#{@account_id}"]
      end
    end

    # An app-like context whose request carries +session+ as its rack.session.
    def context_with(session: nil)
      env = session ? { 'rack.session' => session } : {}
      Struct.new(:request).new(Rack::Request.new(env))
    end

    def session_with_id(id) = double(:session, id: Rack::Session::SessionId.new(id))

    before do
      Sidereal.config.config!('sidereal.signer') { Sidereal::Signer.new('k' * 32) }
      Sidereal.config.build!
      Sidereal::Page.register(page_class)
    end

    it "resolves a token to the page class, its decoded params, the channels the instance named and the session's channel" do
      ctx = context_with(session: session_with_id('s1'))
      token = described_class.stream_token(page_class.new(account_id: 'a9'), { id: '42' }, ctx)

      expect(described_class.resolve_stream(token, ctx)).to eq(
        Sidereal::Page::Stream.new(
          page_class:, params: { id: 42 },
          channels: ['orders.>', 'accounts.a9', described_class.session_channel(ctx)]
        )
      )
      expect(described_class.session_channel(ctx)).to match(/\Asidereal\.sessions\.\h{32}\z/)
    end

    it 'subscribes to no session channel without a session' do
      token = described_class.stream_token(page_class.new(account_id: 'a9'), { id: '42' }, context_with)

      expect(described_class.resolve_stream(token, context_with).channels).to eq(['orders.>', 'accounts.a9'])
      expect(described_class.session_channel(context_with)).to be_nil
    end

    it 'gives a session without an id one, by storing in it, before signing' do
      page = page_class.new
      id_before = token = ctx = nil
      Rack::Session::Cookie.new(->(env) {
        ctx = Struct.new(:request).new(Rack::Request.new(env))
        id_before = env['rack.session'].id
        token = described_class.stream_token(page, { id: '42' }, ctx)
        [200, {}, []]
      }, secret: 'a' * 64).call(Rack::MockRequest.env_for('/'))

      expect(id_before).to be_nil
      expect(ctx.request.env['rack.session'][Sidereal::Page::SESSION_KEY]).to be(true)
      expect(described_class.resolve_stream(token, ctx).channels).to include(described_class.session_channel(ctx))
    end

    it 'accepts a single channel as a String' do
      single = Class.new(Sidereal::Page) do
        path '/single-channel'
        def channel_names = 'orders.1'
      end
      Sidereal::Page.register(single)
      token = described_class.stream_token(single.new, {}, context_with)

      expect(described_class.resolve_stream(token, context_with).channels).to eq(['orders.1'])
    end

    it 'signs no stream for a page whose channels are nil or empty' do
      [nil, []].each do |none|
        silent = Class.new(Sidereal::Page) do
          path '/no-channels'
          define_method(:channel_names) { none }
        end
        Sidereal::Page.register(silent)

        expect(described_class.stream_token(silent.new, {}, context_with)).to be_nil
      end
    end

    it 'resolves without a session when the page rendered without one' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with)

      expect(described_class.resolve_stream(token, context_with)).not_to be_nil
    end

    it 'treats a rack.session without an id, such as a plain Hash, as no session' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with(session: { 'user' => 'ada' }))

      expect(described_class.resolve_stream(token, context_with)).not_to be_nil
    end

    it 'binds a token to the session id however the store hands it back' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with(session: session_with_id('s1')))

      expect(described_class.resolve_stream(token, context_with(session: double(:session, id: 's1')))).not_to be_nil
    end

    it 'rejects a token from another session' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with(session: session_with_id('s1')))

      expect(described_class.resolve_stream(token, context_with(session: session_with_id('s2')))).to be_nil
      expect(described_class.resolve_stream(token, context_with)).to be_nil
    end

    it 'rejects a token signed with another secret' do
      other = Sidereal::Signer.new('b' * 64)
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with, signer: other)

      expect(described_class.resolve_stream(token, context_with)).to be_nil
    end

    it 'rejects a token whose channels were tampered with' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with)
      payload, signature = token.split('.')
      data = JSON.parse(Base64.urlsafe_decode64(payload))
      forged = Base64.urlsafe_encode64(JSON.generate(data.merge('channels' => ['>'])), padding: false)

      expect(described_class.resolve_stream("#{forged}.#{signature}", context_with)).to be_nil
    end

    it 'rejects data the signer signed for another purpose' do
      token = Sidereal.signer.generate({ 'page' => '/orders/:id', 'params' => { 'id' => '1' }, 'channels' => ['>'], 'session' => nil })

      expect(described_class.resolve_stream(token, context_with)).to be_nil
    end

    it 'rejects a token for a page key no class is registered under' do
      gone = Class.new(Sidereal::Page) { path '/gone-page' }
      Sidereal::Page.register(gone)
      token = described_class.stream_token(gone.new, {}, context_with)
      Sidereal::Page.registry.delete('/gone-page')

      expect(described_class.resolve_stream(token, context_with)).to be_nil
    end

    it 'rejects a token whose params no longer decode' do
      token = described_class.stream_token(page_class.new, { id: '42' }, context_with)
      Sidereal::Page.register(Class.new(Sidereal::Page) do
        path '/orders/:id'
        query_schema(id: Sidereal::Types::UUID::V4)
      end)

      expect(described_class.resolve_stream(token, context_with)).to be_nil
    end

    it 'refuses to sign a channel built from a value that is not one plain segment' do
      segment_page = Class.new(Sidereal::Page) do
        path '/segments/:id'
        def initialize(id:) = @id = id
        def channel_names = ["orders.#{channel_segment(@id)}"]
      end
      Sidereal::Page.register(segment_page)

      ['>', '*', 'a.b', '', nil].each do |id|
        expect { described_class.stream_token(segment_page.new(id:), { id: id.to_s }, context_with) }
          .to raise_error(ArgumentError, /not a single plain channel name segment/)
      end
      expect(Sidereal.signer.verify(described_class.stream_token(segment_page.new(id: 'a*b'), { id: 'a*b' }, context_with), purpose: Sidereal::Page::STREAM_PURPOSE))
        .to include('channels' => ['orders.a*b'])
    end

    it 'rejects a token whose data has the wrong shape' do
      signer = Sidereal.signer
      valid = { 'page' => '/orders/:id', 'params' => { 'id' => '1' }, 'channels' => ['orders.1'], 'session' => nil }
      [
        valid.merge('channels' => [1]),
        valid.merge('channels' => [nil]),
        valid.merge('channels' => ['orders..1']),
        valid.merge('channels' => ['>.orders']),
        valid.merge('channels' => 'orders.1'),
        valid.merge('channels' => []),
        valid.merge('page' => ['/orders/:id']),
        valid.merge('params' => 'id=1'),
        valid.merge('params' => [1])
      ].each do |data|
        token = signer.generate(data, purpose: Sidereal::Page::STREAM_PURPOSE)
        expect(described_class.resolve_stream(token, context_with, signer:)).to be_nil, "accepted #{data.inspect}"
      end
      token = signer.generate(valid, purpose: Sidereal::Page::STREAM_PURPOSE)
      expect(described_class.resolve_stream(token, context_with, signer:)).not_to be_nil
    end

    it 'rejects garbage' do
      expect(described_class.resolve_stream('nope', context_with)).to be_nil
      expect(described_class.resolve_stream('a.b.c', context_with)).to be_nil
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

    it 'expands a source that answers sidereal_events into its message classes' do
      source = Module.new do
        def self.sidereal_events = [PageTestItemAdded, PageTestNotification]
      end
      reloading = Class.new(Sidereal::Page) { on source }
      handling = Class.new(Sidereal::Page) { on(source) { |evt| } }

      expect(reloading.correlation_types).to include(PageTestItemAdded.type, PageTestNotification.type)
      expect(handling.reactions.keys).to include(PageTestItemAdded, PageTestNotification)
      expect(handling.reactions[PageTestItemAdded]).to eq(handling.reactions[PageTestNotification])
    end

    it 'rejects a source whose sidereal_events is empty' do
      source = Module.new { def self.sidereal_events = [] }

      expect { Class.new(Sidereal::Page) { on source } }
        .to raise_error(ArgumentError, /answers sidereal_events with nothing/)
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

    it 'register nothing on a page that disabled causal reactivity' do
      page = Class.new(Sidereal::Page) do
        disable_causal_reactivity!
        on PageTestItemAdded

        def view_template
          command PageTestNotification do |f|
            f.text_field :text
          end
        end
      end

      expect(page.causal_reactivity?).to be false
      page.new.call(context:)

      expect(page.correlation_types).to include(PageTestItemAdded.type)
      expect(page.correlation_types).not_to include(PageTestNotification.type)
    end

    it 'inherit a disabled causal reactivity' do
      parent = Class.new(Sidereal::Page) { disable_causal_reactivity! }
      child = Class.new(parent)
      form = item_form
      grandchild = Class.new(child) do
        define_method(:view_template) { render form.new }
      end

      grandchild.new.call(context:)

      expect(Sidereal::Page.causal_reactivity?).to be true
      expect(child.causal_reactivity?).to be false
      expect(grandchild.correlation_types).to be_empty
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
      page_context = page_context_class.new(sse, nil, page_class, params: {})

      evt = PageTestItemAdded.new(payload: { title: 'hello' })
      page_context.react(evt)

      expect(sse.patches.size).to eq(1)
    end

    it 'reloads and patches the page when registered without a block' do
      loaded_with = :unset
      blockless_page = Class.new(Sidereal::Page) do
        path '/blockless/:id'

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

      sse = FakeSSE.new('page_key' => '/blockless/:id', 'params' => { 'id' => '7' })
      page_context = page_context_class.new(sse, nil, blockless_page, params: { id: '7' })

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
      page_context = page_context_class.new(sse, nil, page, params: {})

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
      page_context = page_context_class.new(sse, nil, page, params: {})

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
      page_context = page_context_class.new(sse, nil, page, params: {})

      cmd = PageTestItemAdded.new(payload: { title: 'hello' })
      evt = cmd.correlate(PageTestNotification.new(payload: { text: 'added' }))
      page_context.react(evt)

      expect(handled).to eq([evt])
      expect(sse.patches).to be_empty
    end

    it 'ignores events without a registered handler' do
      sse = FakeSSE.new('page_key' => '/reactive', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class, params: {})

      evt = PageTestNotification.new(payload: { text: 'hi' })
      page_context.react(evt)

      expect(sse.patches).to be_empty
    end

    it 'gives reactions the params it was built with' do
      captured_params = nil
      page_with_params = Class.new(Sidereal::Page) do
        path '/with-params/:id'
        query_schema(id: Sidereal::Types::Integer, filter?: Sidereal::Types::String)
        on PageTestItemAdded do |evt|
          captured_params = params
        end
      end

      sse = FakeSSE.new('page_key' => '/with-params/:id', 'params' => { 'id' => '1' })
      page_context = page_context_class.new(sse, nil, page_with_params, params: { id: 42, filter: 'active' })

      page_context.react(PageTestItemAdded.new(payload: { title: 'test' }))

      expect(captured_params).to eq({ id: 42, filter: 'active' })
    end
  end

  describe '.stream' do
    let(:pubsub) { Sidereal::PubSub::Memory.new }

    it 'renders the page from the given params, then reacts to messages on the channel' do
      loaded = []
      page_class = Class.new(Sidereal::Page) do
        path '/stream/:id'

        define_singleton_method(:load) do |params, _ctx|
          loaded << params
          new
        end

        def view_template = div { 'loaded' }

        on PageTestNotification do |evt|
          browser.patch_elements evt.payload.text
        end
      end
      sse = FakeSSE.new

      Sync do |task|
        channel = pubsub.subscribe('stream.a', 'stream.b')
        runner = task.async { page_class.stream(channel, sse, { id: '42' }, nil) }
        pubsub.publish('stream.b', PageTestNotification.new(payload: { text: 'hello' }))
        channel.stop
        runner.wait
      end

      expect(loaded).to eq([{ id: '42' }])
      expect(sse.patches.map { |patch| patch[:component] }).to match([an_instance_of(page_class), 'hello'])
    end
  end

  describe 'PageContext#run' do
    let(:pubsub) { Sidereal::PubSub::Memory.new }
    let(:sse) { FakeSSE.new('page_key' => '/coalescing', 'params' => {}) }
    # load announces each render on +started+, then parks until +gate+ lets it finish.
    let(:started) { Async::Queue.new }
    let(:gate) { Async::Queue.new }

    let(:page_class) do
      started = self.started
      gate = self.gate
      Class.new(Sidereal::Page) do
        path '/coalescing'

        define_singleton_method(:load) do |_params, _ctx|
          started << :render
          gate.pop
          new
        end

        def view_template = div { 'page' }

        on PageTestItemAdded
        on PageTestNotification do |evt|
          browser.patch_elements evt.payload.text
        end
      end
    end

    def item = PageTestItemAdded.new(payload: { title: 'x' })
    def note(text) = PageTestNotification.new(payload: { text: })

    # Runs the page against a channel. The block publishes and steers renders;
    # afterwards every remaining render is released and the channel stopped.
    def run_page
      Sync do |task|
        channel = pubsub.subscribe('coalescing')
        page_context = Sidereal::Page::PageContext.new(sse, nil, page_class, params: {})
        runner = task.async { page_context.run(channel) }
        yield ->(msg) { pubsub.publish('coalescing', msg) }
        gate.close
        channel.stop
        runner.wait
      end
    end

    def renders = sse.patches.count { |patch| patch[:component].is_a?(page_class) }

    it 'reloads once for a single message' do
      run_page do |publish|
        publish.(item)
        started.pop
      end

      expect(renders).to eq(1)
    end

    it 'renders once more for a burst of reloads arriving during a render' do
      run_page do |publish|
        publish.(item)
        started.pop # first render in flight
        5.times { publish.(item) }
        gate << :go
        started.pop # the trailing render
      end

      expect(renders).to eq(2)
    end

    it 'runs every handler in order and keeps the latest reload in its place' do
      run_page do |publish|
        publish.(item)
        started.pop
        publish.(item)
        publish.(note('a'))
        publish.(note('b'))
        publish.(item)
        gate << :go
        started.pop
      end

      sequence = sse.patches.map { |patch| patch[:component].is_a?(page_class) ? :render : patch[:component] }
      expect(sequence).to eq([:render, 'a', 'b', :render])
    end

    it 'propagates an exception raised by a reaction' do
      failing = Class.new(Sidereal::Page) do
        path '/coalescing-failing'
        def self.load(_params, _ctx) = raise('boom')
        def view_template = div { 'page' }
        on PageTestItemAdded
      end

      expect {
        Sync do |task|
          channel = pubsub.subscribe('failing')
          page_context = Sidereal::Page::PageContext.new(sse, nil, failing, params: {})
          runner = task.async { page_context.run(channel) }
          pubsub.publish('failing', item)
          runner.wait
        end
      }.to raise_error(RuntimeError, 'boom')
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
      page_context = page_context_class.new(sse, nil, page_class, params: {})

      page_context.react(build_retry_evt)

      expect(sse.patches.size).to eq(1)
      patch = sse.patches.first
      expect(patch[:component]).to be_a(Sidereal::Components::SystemNotifyRetry)
      expect(patch[:options]).to eq(mode: 'prepend', selector: '#sidereal-sysnotify-stack')
    end

    it 'reacts to NotifyFailure by patching SystemNotifyFailure to body, prepend mode' do
      sse = FakeSSE.new('page_key' => '/sys', 'params' => {})
      page_context = page_context_class.new(sse, nil, page_class, params: {})

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
      page_context = page_context_class.new(sse, nil, override, params: {})

      evt = build_failure_evt
      page_context.react(evt)

      expect(called_with).to eq(evt)
      # The default patch_elements call should NOT have run.
      expect(sse.patches).to be_empty
    end
  end
end

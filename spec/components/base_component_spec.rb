# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Components::BaseComponent do
  include_context 'tmp files'

  # A class named +name+ before its body runs, as `class Name < parent` is.
  def named(name, parent = described_class, &body)
    stub_const(name, Class.new(parent)).tap { |klass| klass.class_eval(&body) if body }
  end

  def declaration(name, kind, path: nil, content: nil)
    Sidereal::Assets::Declaration.new(name:, kind:, path:, content:)
  end

  describe 'declaring assets' do
    it 'stores stylesheets, scripts and files, with paths relative to the declaring file' do
      component = Class.new(described_class) do
        stylesheet 'chat.css', path: '../chat.css'
        javascript 'chat.js', path: Pathname('assets/chat.js')
        file 'chat/logo.svg', path: '/abs/logo.svg'
        stylesheet 'inline.css', css: 'a {}'
      end

      expect(component.assets).to eq([
        declaration('chat.css', :css, path: File.expand_path('../chat.css', __dir__)),
        declaration('chat.js', :js, path: File.expand_path('assets/chat.js', __dir__)),
        declaration('chat/logo.svg', :file, path: '/abs/logo.svg'),
        declaration('inline.css', :css, content: 'a {}')
      ])
    end

    it 'names inline css and js after the class, numbered for each kind' do
      named('UI::ChatBox') do
        css '.a {}'
        js 'a()'
        css '.b {}'
      end

      expect(UI::ChatBox.assets).to eq([
        declaration('ui/chat_box-1.css', :css, content: '.a {}'),
        declaration('ui/chat_box-1.js', :js, content: 'a()'),
        declaration('ui/chat_box-2.css', :css, content: '.b {}')
      ])
    end

    it "raises for inline assets on a class without a name" do
      expect { Class.new(described_class) { css 'a {}' } }.to raise_error(ArgumentError, /no name/)
    end

    it "lists a superclass's assets first, and a subclass's own numbering" do
      named('Chat') { css '.chat {}' }
      named('LoudChat', Chat) { css '.loud {}' }

      expect(LoudChat.assets.map(&:name)).to eq(%w[chat-1.css loud_chat-1.css])
      expect(Chat.assets.map(&:name)).to eq(%w[chat-1.css])
    end

    it 'gives pages the same declarations' do
      named('ChatPage', Sidereal::Page) { css '.page {}' }

      expect(ChatPage.assets.map(&:name)).to eq(%w[chat_page-1.css])
    end
  end

  describe 'installing' do
    let(:app) { Class.new(Sidereal::App) }

    it "registers the component's assets with the app's, on install" do
      logo = write('logo.svg', '<svg/>')
      named('Chat') do
        css '.chat {}'
        file 'chat/logo.svg', path: logo
      end

      app.component(Chat)

      expect(app.assets.stylesheet_paths).to eq([app.assets.path('chat-1.css')])
      expect(app.assets.registered?('chat/logo.svg')).to be(true)
    end

    it 'registers assets two installed components share only once' do
      named('Chat') { css '.chat {}' }
      named('LoudChat', Chat) { css '.loud {}' }
      named('QuietChat', Chat) { css '.quiet {}' }

      app.component(LoudChat).component(QuietChat).install(Chat)

      expect(app.assets.stylesheet_paths).to eq(%w[chat-1.css loud_chat-1.css quiet_chat-1.css].map { app.assets.path(_1) })
    end

    it 'raises for a name the app has registered to a different asset' do
      app.assets.stylesheet 'chat-1.css', css: '.other {}'
      named('Chat') { css '.chat {}' }

      expect { app.component(Chat) }.to raise_error(Sidereal::Assets::DuplicateAssetError)
    end

    it "registers a page's assets when the app mounts it" do
      named('ChatPage', Sidereal::Page) do
        path '/chat'
        js 'chat()'
      end

      app.page(ChatPage)

      expect(app.assets.javascript_paths).to eq([app.assets.path('chat_page-1.js')])
    end

    it 'mounts a page whose own sidereal_install mounts it' do
      named('ChatPage', Sidereal::Page) do
        path '/chat'
        css '.chat {}'
        def self.sidereal_install(app) = app.page(self)
      end

      app.install(ChatPage)

      expect(app.assets.stylesheet_paths).to eq([app.assets.path('chat_page-1.css')])
    end

    it 'raises ArgumentError for something that is not a page, before registering any assets' do
      named('ChatLayout', Sidereal::Components::Layout) { css '.chat {}' }

      expect { app.page(Object, layout: ChatLayout) }.to raise_error(ArgumentError, /Page subclass/)
      expect(app.assets.registered?('chat_layout-1.css')).to be(false)
    end

    it "doesn't set a layout whose assets can't be registered" do
      app.assets.stylesheet 'app_layout-1.css', css: '.other {}'
      named('AppLayout', Sidereal::Components::Layout) { css '.app {}' }

      expect { app.layout(AppLayout) }.to raise_error(Sidereal::Assets::DuplicateAssetError)
      expect(app.layout).to be(Sidereal::Components::BasicLayout)
    end

    it 'installs a component again once the assets are locked' do
      named('Chat') { css '.chat {}' }
      app.component(Chat)
      app.assets.lock!

      expect { app.component(Chat) }.not_to raise_error
    end

    it "registers a layout's assets when the app sets it, or a page is given it" do
      named('AppLayout', Sidereal::Components::Layout) { css '.app {}' }
      named('ChatLayout', Sidereal::Components::Layout) { css '.chat {}' }
      named('ChatPage', Sidereal::Page) { path '/chat' }

      app.layout(AppLayout)
      app.page(ChatPage, layout: ChatLayout)

      expect(app.assets.stylesheet_paths).to eq(%w[app_layout-1.css chat_layout-1.css].map { app.assets.path(_1) })
    end

    it 'sets a layout that has no assets to install' do
      layout = Class.new { def self.new(page) = page }

      expect { app.layout(layout) }.not_to raise_error
      expect(app.layout).to be(layout)
    end
  end
end

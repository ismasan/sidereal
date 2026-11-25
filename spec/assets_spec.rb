# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Sidereal::Assets do
  subject(:assets) { described_class.new }

  include_context 'tmp files'

  def request(path, method: 'GET', headers: {}, script_name: '')
    env = Rack::MockRequest.env_for(path, method:, 'SCRIPT_NAME' => script_name, **headers)
    assets.call(env)
  end

  def body_of(response) = [].tap { |parts| response[2].each { |part| parts << part } }.join

  def use_mode(mode)
    Sidereal.config.config!('sidereal.assets.mode') { mode }
    Sidereal.config.build!
  end

  describe 'registration' do
    it 'registers stylesheets, scripts and files, from files or inline' do
      assets.stylesheet 'app.css', path: write('app.css', 'body {}')
      assets.javascript 'app.js', js: 'console.log(1)'
      assets.file 'logo.svg', path: write('logo.svg', '<svg/>')

      expect(assets.registered?('app.css')).to be(true)
      expect(assets.registered?('app.js')).to be(true)
      expect(assets.registered?('logo.svg')).to be(true)
      expect(assets.registered?('other.css')).to be(false)
    end

    it 'registers a directory, by extension, with an optional prefix' do
      write('lib/a.css', 'a {}')
      write('lib/nested/b.js', 'b()')
      write('lib/img/logo.png', 'png')
      assets.directory File.join(tmp_dir, 'lib'), prefix: 'acme'

      expect(assets.stylesheet_paths).to contain_exactly(%r{\A/_assets/acme/a-\h{16}\.css\z})
      expect(assets.javascript_paths).to contain_exactly(%r{\A/_assets/acme/nested/b-\h{16}\.js\z})
      expect(assets.path('acme/img/logo.png')).to match(%r{\A/_assets/acme/img/logo-\h{16}\.png\z})
    end

    it 'takes Pathnames' do
      write('lib/a.css', 'a {}')
      assets.directory Pathname(tmp_dir).join('lib')
      assets.file 'b.txt', path: Pathname(write('b.txt', 'b'))

      expect(assets.registered?('a.css')).to be(true)
      expect(assets.registered?('b.txt')).to be(true)
    end

    it 'raises for a missing file, at registration' do
      expect { assets.stylesheet 'app.css', path: File.join(tmp_dir, 'nope.css') }
        .to raise_error(ArgumentError, /no file at/)
    end

    it 'raises without a path or content, or with both' do
      expect { assets.stylesheet 'app.css' }.to raise_error(ArgumentError)
      expect { assets.stylesheet 'app.css', path: write('a.css', ''), css: 'a {}' }.to raise_error(ArgumentError)
    end

    it 'raises for a name without the extension of its type' do
      expect { assets.stylesheet 'app', css: 'a {}' }.to raise_error(ArgumentError, /extension/)
      expect { assets.javascript 'app.css', js: 'a()' }.to raise_error(ArgumentError, /\.js/)
      expect { assets.stylesheet '/app.css', css: 'a {}' }.to raise_error(ArgumentError, /relative/)
    end

    it "raises for a bundle's name" do
      expect { assets.stylesheet 'bundle.css', css: 'a {}' }.to raise_error(ArgumentError, /bundle/)
    end

    it 'raises for a name already registered, here or in the parent' do
      assets.stylesheet 'app.css', css: 'a {}'
      expect { assets.stylesheet 'app.css', css: 'b {}' }.to raise_error(described_class::DuplicateAssetError)

      child = described_class.new(assets)
      expect { child.javascript 'app.css', js: '' }.to raise_error(ArgumentError)
      expect { child.stylesheet 'app.css', css: 'b {}' }.to raise_error(described_class::DuplicateAssetError)
    end

    it 'does nothing for the same asset registered again once locked, and raises for a new one' do
      assets.stylesheet 'app.css', css: 'a {}'
      assets.lock!

      expect { assets.stylesheet 'app.css', css: 'a {}' }.not_to raise_error
      expect { assets.stylesheet 'app.css', css: 'b {}' }.to raise_error(described_class::LockedError)
      expect { assets.stylesheet 'new.css', css: 'b {}' }.to raise_error(described_class::LockedError)
    end

    it 'does nothing for the same asset registered again, here or in the parent' do
      path = write('app.css', 'a {}')
      assets.stylesheet 'app.css', path: path
      assets.javascript 'app.js', js: 'a()'
      child = described_class.new(assets)

      expect { assets.stylesheet 'app.css', path: path }.not_to raise_error
      expect { child.javascript 'app.js', js: 'a()' }.not_to raise_error
      expect { child.javascript 'app.js', js: 'b()' }.to raise_error(described_class::DuplicateAssetError)
      expect(child.stylesheet_paths).to eq([child.path('app.css')])
      expect(child.javascript_paths).to eq([child.path('app.js')])
    end

    it 'locks once a path is read, with its parent' do
      parent = described_class.new
      child = described_class.new(parent)
      child.stylesheet 'app.css', css: 'a {}'
      child.stylesheet_paths

      expect(child.locked?).to be(true)
      expect(parent.locked?).to be(true)
      expect { parent.stylesheet 'late.css', css: 'b {}' }.to raise_error(described_class::LockedError)
    end
  end

  describe 'paths and digests' do
    it "digests an asset's content" do
      assets.stylesheet 'a.css', css: 'a {}'
      assets.stylesheet 'b.css', css: 'a {}'
      assets.stylesheet 'c.css', css: 'c {}'

      expect(assets.digest('a.css')).to eq(assets.digest('b.css'))
      expect(assets.digest('a.css')).not_to eq(assets.digest('c.css'))
      expect(assets.path('a.css')).to eq("/_assets/a-#{assets.digest('a.css')}.css")
    end

    it 'raises for an unknown asset' do
      expect { assets.path('nope.css') }.to raise_error(described_class::UnknownAssetError)
    end

    it "keeps an asset's digest while its file is unchanged, and changes it when the file does" do
      css = write('app.css', 'a {}')
      assets.stylesheet 'app.css', path: css
      assets.javascript 'app.js', path: write('app.js', 'a()')
      before = assets.path('app.css')
      js_before = assets.path('app.js')

      expect(assets.path('app.css')).to eq(before)
      write('app.css', 'b {}')
      expect(assets.path('app.css')).not_to eq(before)
      expect(assets.path('app.js')).to eq(js_before)
    end

    it "doesn't re-read a stylesheet whose file's modification time and size are unchanged" do
      css = write('app.css', 'a {}')
      assets.stylesheet 'app.css', path: css
      before = assets.path('app.css')
      mtime = File.mtime(css)

      write('app.css', 'b {}')
      File.utime(mtime, mtime, css)

      expect(assets.path('app.css')).to eq(before)
    end

    it "computes digests once in :single mode with sidereal.assets.watch off, and still serves a file's new content" do
      Sidereal.config.config!('sidereal.assets.watch') { false }
      use_mode(:single)
      assets.stylesheet 'app.css', path: write('app.css', 'a {}')
      assets.javascript 'app.js', path: write('app.js', 'a()')
      before = assets.stylesheet_paths
      js_before = assets.javascript_paths

      write('app.css', 'b {}')
      write('app.js', 'b()')

      expect(assets.stylesheet_paths).to eq(before)
      expect(assets.javascript_paths).to eq(js_before)
      expect(request(before.first).first).to eq(302)
    end

    it 'turns sidereal.assets.watch off by default in production only' do
      original = Sidereal.environment
      { 'production' => false, 'development' => true, 'test' => true }.each do |env, watch|
        Sidereal.environment = env
        Sidereal.reset_config!
        Sidereal.config.build!

        expect(Sidereal.config['sidereal.assets.watch']).to be(watch)
      end
    ensure
      Sidereal.environment = original
    end

    it 'computes digests once in :combined mode' do
      use_mode(:combined)
      assets.stylesheet 'app.css', path: write('app.css', 'a {}')
      before = assets.path('app.css')
      write('app.css', 'b {}')

      expect(assets.path('app.css')).to eq(before)
    end

    it "never serves a file's new content under its old digest, in :combined mode" do
      use_mode(:combined)
      assets.stylesheet 'app.css', path: write('app.css', 'a {}')
      assets.javascript 'app.js', path: write('app.js', 'a()')
      assets.file 'logo.svg', path: write('logo.svg', '<svg/>')
      old_css = assets.path('app.css')
      old_svg = assets.path('logo.svg')
      old_bundle = assets.bundle_path(:js)
      write('app.css', 'b {}')
      write('logo.svg', '<svg id="b"/>')
      write('app.js', 'b()')

      status, headers, = request(old_css)
      expect(status).to eq(302)
      expect(headers['location']).to eq(assets.path('app.css'))
      expect(assets.path('app.css')).not_to eq(old_css)
      expect(body_of(request(assets.path('app.css')))).to eq('b {}')

      expect(request(old_svg).first).to eq(302)
      expect(body_of(request(assets.path('logo.svg')))).to eq('<svg id="b"/>')

      status, headers, = request(old_bundle)
      expect(status).to eq(302)
      expect(body_of(request(headers['location']))).to eq('b()')
    end

    it 'unescapes the requested path' do
      assets.stylesheet 'my app.css', css: 'a {}'
      expect(request(assets.path('my app.css').sub(' ', '%20')).first).to eq(200)
    end

    it 'lists paths in registration order, the parent first' do
      parent = described_class.new
      parent.stylesheet 'base.css', css: 'base {}'
      child = described_class.new(parent)
      child.stylesheet 'app.css', css: 'app {}'
      child.javascript 'app.js', js: 'app()'

      expect(child.stylesheet_paths).to eq([child.path('base.css'), child.path('app.css')])
      expect(child.javascript_paths).to eq([child.path('app.js')])
    end

    it 'links the bundles in :combined mode' do
      use_mode(:combined)
      assets.stylesheet 'a.css', css: 'a {}'
      assets.stylesheet 'b.css', css: 'b {}'

      expect(assets.stylesheet_paths).to eq([assets.bundle_path(:css)])
      expect(assets.bundle_path(:css)).to match(%r{\A/_assets/bundle-\h{16}\.css\z})
      expect(assets.javascript_paths).to eq([])
    end

    it "computes a bundle's digest from its assets'" do
      css = write('a.css', 'a {}')
      assets.stylesheet 'a.css', path: css
      assets.stylesheet 'b.css', css: 'b {}'
      assets.javascript 'a.js', js: 'a()'
      before = assets.bundle_digest(:css)
      js_before = assets.bundle_digest(:js)

      expect(assets.bundle_digest(:css)).to eq(before)
      write('a.css', 'changed {}')
      expect(assets.bundle_digest(:css)).not_to eq(before)
      expect(assets.bundle_digest(:js)).to eq(js_before)
    end

    it 'starts URLs with the host and the mount path' do
      assets.stylesheet 'a.css', css: 'a {}'
      expect(assets.href(assets.path('a.css'), script_name: '/admin')).to eq("/admin#{assets.path('a.css')}")

      Sidereal.config.config!('sidereal.assets.host') { 'https://cdn.example.com/' }
      Sidereal.config.build!
      expect(assets.href('/_assets/x.css', script_name: '/admin')).to eq('https://cdn.example.com/admin/_assets/x.css')
    end
  end

  describe 'url() references in stylesheets' do
    before do
      write('styles/img/logo.svg', '<svg/>')
      write('styles/fonts/a.woff2', 'font')
      assets.directory File.join(tmp_dir, 'styles')
    end

    it 'rewrites relative references to registered files to their digested paths, relative to the URL' do
      write('styles/acme/charts.css', <<~CSS)
        .a { background: url("../img/logo.svg"); }
        .b { src: url(../fonts/a.woff2?v=1#iefix); }
        .c { background: url(data:image/png;base64,xx); }
        .d { background: url(/elsewhere.png); }
        .e { background: url('../img/unregistered.png'); }
      CSS
      assets.stylesheet 'acme/charts.css', path: File.join(tmp_dir, 'styles/acme/charts.css')

      body = body_of(request(assets.path('acme/charts.css')))
      expect(body).to include(%(url("../img/logo-#{assets.digest('img/logo.svg')}.svg")))
      expect(body).to include("url(../fonts/a-#{assets.digest('fonts/a.woff2')}.woff2?v=1#iefix)")
      expect(body).to include('url(data:image/png;base64,xx)')
      expect(body).to include('url(/elsewhere.png)')
      expect(body).to include(%(url('../img/unregistered.png')))

      bundled = body_of(request(assets.bundle_path(:css)))
      expect(bundled).to include(%(url("img/logo-#{assets.digest('img/logo.svg')}.svg")))
    end

    it "changes a stylesheet's digest when a file it references changes" do
      write('page.css', '.a { background: url(styles/img/logo.svg); }')
      assets.stylesheet 'page.css', path: File.join(tmp_dir, 'page.css')
      before = assets.digest('page.css')

      write('styles/img/logo.svg', '<svg id="new"/>')
      expect(assets.digest('page.css')).not_to eq(before)
    end
  end

  describe '#call' do
    it 'serves an asset with long-lived caching headers' do
      assets.stylesheet 'app.css', css: 'a {}'
      status, headers, body = request(assets.path('app.css'))

      expect(status).to eq(200)
      expect(headers['cache-control']).to eq('public, max-age=31536000, immutable')
      expect(headers['content-type']).to eq('text/css; charset=utf-8')
      expect(headers['etag']).to eq(%("#{assets.digest('app.css')}"))
      expect(headers['content-length']).to eq('4')
      expect(body.to_a.join).to eq('a {}')
    end

    it 'streams files from disk' do
      png = "\x89PNG\r\n".b * 2000
      assets.file 'img/logo.png', path: write('logo.png', png)
      status, headers, body = request(assets.path('img/logo.png'))

      expect(status).to eq(200)
      expect(headers['content-type']).to eq('image/png')
      expect(headers['content-length']).to eq(png.bytesize.to_s)
      expect(body.to_path).to eq(File.join(tmp_dir, 'logo.png'))
      expect(body_of([status, headers, body]).b).to eq(png)
    end

    it 'serves bundles, joined in order' do
      assets.stylesheet 'a.css', css: 'a {}'
      assets.stylesheet 'b.css', css: 'b {}'
      assets.javascript 'a.js', js: 'a()'
      assets.javascript 'b.js', js: 'b()'

      expect(body_of(request(assets.bundle_path(:css)))).to eq("a {}\nb {}")
      js = request(assets.bundle_path(:js))
      expect(js[1]['content-type']).to eq('text/javascript; charset=utf-8')
      expect(body_of(js)).to eq("a();\nb()")
    end

    it "redirects, and doesn't cache, a bundle whose assets change while it's built" do
      path = write('app.js', 'one()')
      assets.javascript 'app.js', path: path
      stale = assets.bundle_path(:js)
      changed = false
      allow(File).to receive(:read).and_wrap_original do |original, *args|
        unless changed
          changed = true
          write('app.js', 'two()')
        end
        original.call(*args)
      end

      response = request(stale)
      expect(response.first).to eq(302)
      expect(response[1]['location']).not_to eq(stale)
      expect(body_of(request(response[1]['location']))).to eq('two()')
    end

    it 'serves every file under the digest of what it serves, while it changes, across threads' do
      path = write('app.js', 'v0()')
      assets.javascript 'app.js', path: path
      assets.path('app.js')

      writer = Thread.new do
        1.upto(50) { |i| write('app.js', "v#{i}();" * i) }
      end
      mismatches = Array.new(4) do
        Thread.new do
          Array.new(100) do
            response = request(assets.path('app.js'))
            next unless response.first == 200

            requested = response[1]['etag'].delete('"')
            served = Digest::SHA256.hexdigest(body_of(response))[0, 16]
            requested == served ? nil : [requested, served]
          end.compact
        end
      end.flat_map(&:value)
      writer.join

      expect(mismatches).to be_empty
    end

    it 'answers a matching If-None-Match with a 304' do
      assets.stylesheet 'app.css', css: 'a {}'
      status, headers, body = request(assets.path('app.css'), headers: { 'HTTP_IF_NONE_MATCH' => %("#{assets.digest('app.css')}") })

      expect(status).to eq(304)
      expect(headers['etag']).to eq(%("#{assets.digest('app.css')}"))
      expect(body).to eq([])
    end

    it 'answers HEAD without a body' do
      assets.stylesheet 'app.css', css: 'a {}'
      status, headers, body = request(assets.path('app.css'), method: 'HEAD')

      expect(status).to eq(200)
      expect(headers['content-length']).to eq('4')
      expect(body).to eq([])
    end

    it 'redirects a stale digest to the current URL, uncached, under the mount path' do
      assets.stylesheet 'app.css', css: 'a {}'
      assets.stylesheet 'b.css', css: 'b {}'

      status, headers, = request('/_assets/app-0000000000000000.css', script_name: '/admin')
      expect(status).to eq(302)
      expect(headers['location']).to eq("/admin#{assets.path('app.css')}")
      expect(headers['cache-control']).to eq('no-cache')

      status, headers, = request('/_assets/bundle-0000000000000000.css')
      expect(status).to eq(302)
      expect(headers['location']).to eq(assets.bundle_path(:css))
    end

    it 'returns 404 for unknown assets, undigested paths and empty bundles' do
      assets.stylesheet 'app.css', css: 'a {}'

      expect(request('/_assets/nope-0000000000000000.css').first).to eq(404)
      expect(request('/_assets/app.css').first).to eq(404)
      expect(request('/_assets/bundle-0000000000000000.js').first).to eq(404)
    end
  end

  describe '#digests' do
    it 'returns the digest of every asset, or of every asset of a kind, recomputed when a file changes' do
      use_mode(:combined)
      assets.stylesheet 'app.css', css: 'a {}'
      assets.file 'logo.svg', path: write('logo.svg', '<svg/>')
      before = assets.digests

      expect(before.keys).to eq(%w[app.css logo.svg])
      expect(assets.digests(:file).keys).to eq(%w[logo.svg])

      write('logo.svg', '<svg></svg>')
      expect(assets.digests['logo.svg']).not_to eq(before['logo.svg'])
      expect(assets.digests['app.css']).to eq(before['app.css'])
    end
  end

  describe '.registries' do
    it 'lists the registries in use' do
      registry = assets
      expect(described_class.registries).to include(registry)
    end
  end

  describe Sidereal::Assets::Watcher do
    subject(:assets) { Sidereal::Assets.new }
    let(:pubsub) { Sidereal::PubSub::Memory.new }
    let(:watcher) { watcher_for(enabled: true) }

    # A watcher that checks only this example's registry, not those other
    # examples left behind.
    def watcher_for(enabled:)
      registry = assets
      described_class.new(pubsub:, elector: Sidereal::Elector::AlwaysLeader.new, enabled:, interval: 0.01,
                          registries: -> { [registry] })
    end

    # Register a stylesheet from a file, and lock the registry by rendering
    # its path, as the app does once it renders a page. Returns its path.
    def stylesheet_in_use
      path = write('app.css', 'a {}')
      assets.stylesheet 'app.css', path: path
      assets.path('app.css')
      path
    end

    def published
      [].tap do |messages|
        channel = pubsub.subscribe(Sidereal::Assets::CHANNEL)
        Sync do |task|
          reader = task.async { channel.start { |message, _| messages << message } }
          yield
          channel.stop
          reader.wait
        end
      end
    end

    it 'publishes Changed when an asset in use changes, after recording them on the first check' do
      stylesheet_in_use

      messages = published do
        expect(watcher.check).to be(false)
        expect(watcher.check).to be(false)
        write('app.css', 'b {}')
        expect(watcher.check).to be(true)
        expect(watcher.check).to be(false)
      end

      expect(messages).to match([an_instance_of(Sidereal::Assets::Changed)])
    end

    it 'keeps the last digests of a registry while one of its files is missing' do
      path = stylesheet_in_use
      watcher.check

      File.delete(path)
      expect(watcher.check).to be(false)
      write('app.css', 'a {}')
      expect(watcher.check).to be(false)
      write('app.css', 'b {}')
      expect(watcher.check).to be(true)
    end

    it "doesn't read, or lock, a registry still being filled" do
      assets.stylesheet 'app.css', css: 'a {}'
      watcher.check

      expect(assets).not_to be_locked
    end

    it 'checks on its own once started, while this process leads' do
      stylesheet_in_use

      messages = published do
        Async { |task| watcher.start(task) }
        sleep 0.05
        write('app.css', 'b {}')
        sleep 0.05
        watcher.stop
      end

      expect(messages).not_to be_empty
    end

    it 'does nothing when not enabled' do
      disabled = watcher_for(enabled: false)
      stylesheet_in_use

      messages = published do
        Async { |task| disabled.start(task) }
        write('app.css', 'b {}')
        sleep 0.05
      end

      expect(messages).to be_empty
    end
  end
end

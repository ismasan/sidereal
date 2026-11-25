# frozen_string_literal: true

require 'digest'
require 'pathname'
require 'rack/files'
require 'rack/mime'

module Sidereal
  # An app's local static assets: stylesheets, scripts, and other files such as
  # images and fonts. {App.assets} returns one per app class, and the app serves
  # it under {PREFIX}.
  #
  #   class MyApp < Sidereal::App
  #     assets.stylesheet 'app.css', path: Sidereal.root.join('assets/app.css')
  #     assets.javascript 'app.js', js: "console.log('hi')"
  #     assets.file 'logo.svg', path: Sidereal.root.join('assets/logo.svg')
  #     assets.directory Sidereal.root.join('assets')
  #   end
  #
  # Every URL carries a digest of what it serves, so it can be cached for good:
  #
  # - Each asset has its own URL, +/_assets/logo-<digest>.svg+, whose digest
  #   changes only when that asset does.
  # - The stylesheets, and the scripts, are also served combined into one
  #   bundle each, +/_assets/bundle-<digest>.css+, whose digest is computed from
  #   the digests of the assets it combines.
  #
  # The +sidereal.assets.mode+ component picks which of them layouts link to
  # (see {#stylesheet_paths}): +:single+ links each asset, and notices when a
  # file changes, so an edit shows without a restart, unless
  # +sidereal.assets.watch+ is off, as it is in production. +:combined+ links the
  # bundles, and digests each asset once for them. Serving checks a file against
  # its digest in either mode. The server serves both kinds of URL in
  # either mode. A URL whose digest isn't the current one is redirected to the
  # current URL, uncached, as for a page rendered before a deploy.
  #
  # Assets are registered as the app's classes load: once something reads a
  # path or serves a request, the registry, and its parent's, lock. An app's
  # registry reads its superclass's, which come first.
  #
  # Stylesheets loaded from a file have their relative +url(...)+ references to
  # registered files rewritten to those files' digested URLs, so a stylesheet's
  # digest changes when a file it references does.
  #
  # Only the bundles are kept in memory, one per type, replaced when their
  # digest changes. Files are read from disk when served, and other files are
  # streamed from it.
  #
  # With +sidereal.assets.live_reload+ on, a {Watcher} publishes {Changed} on
  # {CHANNEL} when a file changes, and open pages update their stylesheets,
  # images and scripts. See {LiveReload}.
  class Assets
    PREFIX = '/_assets'
    # The pubsub channel {Changed} is published on, which page streams
    # subscribe to when live reload is on.
    CHANNEL = 'sidereal.assets'
    # What the path of every asset request starts with.
    PATH_PREFIX = "#{PREFIX}/".freeze
    MODES = %i[single combined].freeze

    # Cache headers for a URL whose digest matches what it serves.
    IMMUTABLE = 'public, max-age=31536000, immutable'

    # Raised for a name already registered, here or in the parent, to a
    # different asset. Registering the same asset again does nothing.
    DuplicateAssetError = Class.new(Sidereal::Error)
    LockedError = Class.new(Sidereal::Error)
    UnknownAssetError = Class.new(Sidereal::Error)

    DIGEST_LENGTH = 16
    KINDS = %i[css js file].freeze
    BUNDLE_NAMES = { css: 'bundle.css', js: 'bundle.js' }.freeze
    BUNDLE_SEPARATORS = { css: "\n", js: ";\n" }.freeze
    DIGESTED_PATH = /\A(?<stem>.+)-(?<digest>\h{#{DIGEST_LENGTH}})(?<ext>\.[^.\/]+)\z/
    # +url(...)+ in CSS, quoted or not
    CSS_URL = /url\(\s*(['"]?)([^'")]+?)\1\s*\)/
    # References left as they are: URLs with a scheme (data:, https:),
    # root-relative paths and fragments.
    EXTERNAL_REF = %r{\A(?:[a-z][a-z0-9+.\-]*:|/|#)}i
    NOT_FOUND = [404, { 'content-type' => 'text/plain', 'cache-control' => 'no-cache' }.freeze, ['Not found'].freeze].freeze

    private_constant :DIGEST_LENGTH, :KINDS, :BUNDLE_NAMES, :BUNDLE_SEPARATORS, :DIGESTED_PATH,
                     :CSS_URL, :EXTERNAL_REF, :NOT_FOUND

    # A digest, and the modification time and size of the file it was computed
    # from, if any. Cached as one value, so a reader never pairs one's digest
    # with another's stamp.
    Cached = Data.define(:digest, :stamp)

    # An asset that a component or page declares, to register with an app's
    # assets when it's installed. See {Components::BaseComponent.stylesheet}.
    #
    # @!attribute kind
    #   @return [:css, :js, :file]
    # @!attribute path
    #   @return [String, nil] the file, an absolute path, or +nil+ for inline
    #   content
    Declaration = Data.define(:name, :kind, :path, :content) do
      # Register this asset with +assets+.
      #
      # @param assets [Assets]
      # @return [Assets]
      def register_in(assets)
        case kind
        when :css then assets.stylesheet(name, path:, css: content)
        when :js then assets.javascript(name, path:, js: content)
        else assets.file(name, path:)
        end
      end
    end

    # A registered asset. It caches its digest, behind a lock, since requests
    # in other threads read and replace it.
    class Asset
      attr_reader :name, :kind, :source_path, :content

      def initialize(name:, kind:, source_path: nil, content: nil)
        @name = name
        @kind = kind
        @source_path = source_path
        @content = content
        @cached = nil
        @lock = Mutex.new
      end

      # @return [Cached, nil]
      def cached = @lock.synchronize { @cached }

      # Cache +digest+, computed from the file as it was at +stamp+.
      # @return [String] the digest
      def cache(digest, stamp = nil)
        @lock.synchronize { @cached = Cached.new(digest:, stamp:) }
        digest
      end

      # The file's modification time and size.
      def stamp
        stat = File.stat(source_path)
        [stat.mtime, stat.size]
      end

      def file? = !source_path.nil?
      def ext = File.extname(name)
      def read = file? ? File.read(source_path) : content
      def digested_name(digest) = "#{name.delete_suffix(ext)}-#{digest}#{ext}"

      def content_type
        type = Rack::Mime.mime_type(ext, 'application/octet-stream')
        kind == :file ? type : "#{type}; charset=utf-8"
      end
    end

    # Published on {CHANNEL} when a registered file changes. It carries
    # nothing: each page stream works out what changed for its own page.
    Changed = Sidereal::Message.define('sidereal.assets.changed')

    REGISTRIES = ObjectSpace::WeakMap.new
    REGISTRIES_LOCK = Mutex.new
    private_constant :REGISTRIES, :REGISTRIES_LOCK

    # Every registry still in use, for the {Watcher} to check. Held weakly, so
    # the registries of app classes a reload replaced drop out.
    #
    # @return [Array<Assets>]
    def self.registries = REGISTRIES_LOCK.synchronize { REGISTRIES.keys }

    # The +key+ component's value, or +default+ while the components aren't
    # built, as in a script that renders without starting the app.
    #
    # @param key [String]
    # @return [Object]
    def self.setting(key, default)
      Sidereal.config[key]
    rescue Sourced::Component::NotBuiltError
      default
    end

    # @param parent [Assets, nil] the registry whose assets come before this one's
    def initialize(parent = nil)
      REGISTRIES_LOCK.synchronize { REGISTRIES[self] = true }
      @parent = parent
      @assets = {}
      @bundles = {}
      @locked = false
      # Guards the registry and the bundle cache, which requests in other
      # threads read and replace.
      @lock = Mutex.new
    end

    # Register a stylesheet, from a file or inline.
    #
    # @param name [String] its name, ending in +.css+, ex. +"acme/charts.css"+
    # @param path [String, nil] the file to read it from
    # @param css [String, nil] its content
    # @return [self]
    def stylesheet(name, path: nil, css: nil) = register(name, :css, path, css)

    # Register a script, from a file or inline. Scripts are loaded as ES
    # modules. Combined, they share one module, so each must stand on its own:
    # no imports of other registered scripts, and no top-level names they share.
    #
    # @param name [String] its name, ending in +.js+
    # @param path [String, nil] the file to read it from
    # @param js [String, nil] its content
    # @return [self]
    def javascript(name, path: nil, js: nil) = register(name, :js, path, js)

    # Register any other file, such as an image or a font. Files are never
    # combined.
    #
    # @param name [String] its name, with its extension, ex. +"acme/logo.svg"+
    # @param path [String] the file
    # @return [self]
    def file(name, path:) = register(name, :file, path, nil)

    # Register every file under +dir+, named by its path relative to it, sorted.
    # +.css+ files are stylesheets, +.js+ files scripts, and the rest files.
    # Files added to the directory later aren't registered.
    #
    # @param dir [String]
    # @param prefix [String, nil] prepended to each name, ex. +"acme"+
    # @return [self]
    def directory(dir, prefix: nil)
      root = File.expand_path(dir)
      raise ArgumentError, "no directory at #{root}" unless File.directory?(root)

      Dir.glob('**/*', base: root).sort.each do |relative|
        full = File.join(root, relative)
        next unless File.file?(full)

        kind = case File.extname(relative)
               when '.css' then :css
               when '.js' then :js
               else :file
               end
        register(prefix ? File.join(prefix, relative) : relative, kind, full, nil)
      end
      self
    end

    # @param name [String]
    def registered?(name) = !find(name).nil?

    def locked? = @lock.synchronize { @locked }

    # Lock this registry and its parent's: registering raises from now on.
    # @return [self]
    def lock!
      @parent&.lock!
      @lock.synchronize { @locked = true }
      self
    end

    # @return [Symbol] the +sidereal.assets.mode+ component, or +:single+ when
    #   the components aren't built
    def mode = self.class.setting('sidereal.assets.mode', :single)

    # @return [String, nil] the +sidereal.assets.host+ component: a host, ex.
    #   a CDN's, that asset URLs start with
    def host = self.class.setting('sidereal.assets.host', nil)

    # The current digest of an asset.
    #
    # @param name [String]
    # @return [String]
    # @raise [UnknownAssetError]
    def digest(name) = digest_of(fetch(name))

    # The digest of every asset, or of every asset of +kind+, by name, each
    # recomputed if its file changed, whatever the {#mode}.
    #
    # @param kind [:css, :js, :file, nil]
    # @return [Hash{String => String}]
    def digests(kind = nil)
      lock!
      assets = kind ? members(kind) : all
      assets.to_h { |asset| [asset.name, digest_of(asset, true)] }
    end

    # The current digest of a bundle, computed from its assets' digests.
    #
    # @param kind [:css, :js]
    # @return [String]
    def bundle_digest(kind)
      lock!
      bundle_digest_of(kind, watching?)
    end

    # The path of an asset, under {PREFIX}, ex. +"/_assets/acme/logo-<digest>.svg"+.
    # Relative to the app: {#href} makes a URL of it.
    #
    # @param name [String]
    # @return [String]
    # @raise [UnknownAssetError]
    def path(name)
      asset = fetch(name)
      "#{PREFIX}/#{asset.digested_name(digest_of(asset))}"
    end

    # The path of a bundle, ex. +"/_assets/bundle-<digest>.css"+.
    #
    # @param kind [:css, :js]
    # @return [String]
    def bundle_path(kind)
      "#{PREFIX}/#{BUNDLE_NAMES.fetch(kind).delete_suffix(".#{kind}")}-#{bundle_digest(kind)}.#{kind}"
    end

    # The paths of the stylesheets a layout links, for the {#mode}: each one in
    # +:single+ mode, or their bundle in +:combined+ mode. Empty without any.
    #
    # @return [Array<String>]
    def stylesheet_paths = paths_for(:css)

    # The paths of the scripts a layout loads. See {#stylesheet_paths}.
    #
    # @return [Array<String>]
    def javascript_paths = paths_for(:js)

    # The URLs of the stylesheets a layout links: the {#stylesheet_paths},
    # each through {#href}.
    #
    # @param script_name [String] the app's mount path
    # @return [Array<String>]
    def stylesheet_hrefs(script_name: '') = stylesheet_paths.map { |path| href(path, script_name:) }

    # The URLs of the scripts a layout loads. See {#stylesheet_hrefs}.
    #
    # @param script_name [String] the app's mount path
    # @return [Array<String>]
    def javascript_hrefs(script_name: '') = javascript_paths.map { |path| href(path, script_name:) }

    # A URL for +path+: the {#host}, if any, the app's mount path, and +path+.
    #
    # @param path [String] from {#path}, {#bundle_path} or the +*_paths+ methods
    # @param script_name [String] the app's mount path
    # @return [String]
    def href(path, script_name: '')
      "#{host&.chomp('/')}#{script_name}#{path}"
    end

    # Serve a GET or HEAD request for an asset or a bundle, its path relative
    # to the app.
    #
    # @param env [Hash] the Rack environment
    # @return [Array(Integer, Hash, #each)]
    def call(env)
      lock!
      match = DIGESTED_PATH.match(Rack::Utils.unescape_path(env[Rack::PATH_INFO].to_s).delete_prefix(PATH_PREFIX))
      return NOT_FOUND unless match

      name = "#{match[:stem]}#{match[:ext]}"
      if (kind = BUNDLE_NAMES.key(name))
        serve_bundle(env, kind, match[:digest])
      elsif (asset = find(name))
        serve_asset(env, asset, match[:digest])
      else
        NOT_FOUND
      end
    end

    protected

    # Every asset, the parent's first, in registration order.
    # @return [Array<Asset>]
    def all = @parent ? @parent.all + @assets.values : @assets.values

    def find(name) = @assets[name] || @parent&.find(name)

    private

    def register(name, kind, source_path, content)
      @lock.synchronize { register_unlocked(name, kind, source_path, content) }
    end

    def register_unlocked(name, kind, source_path, content)
      raise ArgumentError, "an asset needs a path or its content, not both: #{name}" unless source_path.nil? ^ content.nil?
      raise ArgumentError, "#{name} is a bundle's name" if BUNDLE_NAMES.value?(name)
      raise ArgumentError, "an asset's name is relative: #{name}" if name.start_with?('/')
      raise ArgumentError, "#{name} needs an extension" if File.extname(name).empty?
      raise ArgumentError, "a #{kind} asset's name ends in .#{kind}: #{name}" if kind != :file && File.extname(name) != ".#{kind}"
      source_path = File.expand_path(source_path) if source_path
      existing = find(name)
      # The same asset again, as when two components that share an ancestor
      # are installed, is already registered, locked or not.
      return self if existing && existing.kind == kind && existing.source_path == source_path && existing.content == content
      raise LockedError, "can't register #{name}: assets are locked once they are read or served" if @locked
      raise DuplicateAssetError, "#{name} is already registered" if existing
      raise ArgumentError, "no file at #{source_path} for #{name}" if source_path && !File.file?(source_path)

      @assets[name] = Asset.new(name:, kind:, source_path:, content:)
      self
    end

    def fetch(name)
      lock!
      find(name) || raise(UnknownAssetError, "no asset named #{name}")
    end

    def members(kind) = all.select { |asset| asset.kind == kind }

    def paths_for(kind)
      lock!
      return members(kind).map { |asset| path(asset.name) } unless mode == :combined

      members(kind).empty? ? [] : [bundle_path(kind)]
    end

    # +:single+ mode watches files when it renders paths, unless
    # +sidereal.assets.watch+ is off. Serving always does, so it never sends a
    # file's new content under its old digest.
    def watching? = mode == :single && watch?

    # @return [Boolean] the +sidereal.assets.watch+ component, or +true+ when
    #   the components aren't built
    def watch? = self.class.setting('sidereal.assets.watch', true)

    # With +fresh+, a file's digest is recomputed when its modification time
    # or size changes. A stylesheet's is also recomputed when the digest of a
    # file it references changes. Without, the cached digest stands.
    #
    # The stamp is taken before the file is read, so if the file changes while
    # it's read, the cached stamp is out of date and the next fresh digest
    # recomputes it.
    def digest_of(asset, fresh = watching?)
      cached = asset.cached
      return cached.digest if cached && !(fresh && asset.file?)
      return asset.cache(hexdigest(asset.read)) unless asset.file?
      return css_digest_of(asset, cached, fresh) if asset.kind == :css

      stamp = asset.stamp
      return cached.digest if cached && cached.stamp == stamp

      digest =
        if asset.kind == :file
          Digest::SHA256.file(asset.source_path).hexdigest[0, DIGEST_LENGTH]
        else
          hexdigest(asset.read)
        end
      asset.cache(digest, stamp)
    end

    # A stylesheet's stamp is its file's, with the digests of the files it
    # references, as {#rewrite_css} rewrote them.
    CssStamp = Data.define(:file, :refs)
    private_constant :CssStamp

    def css_digest_of(asset, cached, fresh)
      stamp = asset.stamp
      if cached&.stamp.is_a?(CssStamp) && cached.stamp.file == stamp &&
         cached.stamp.refs.all? { |target, digest| digest_of(target, fresh) == digest }
        return cached.digest
      end

      refs = []
      body = rewrite_css(asset, asset.read, File.dirname(asset.name), fresh, refs)
      asset.cache(hexdigest(body), CssStamp.new(file: stamp, refs:))
    end

    def hexdigest(string) = Digest::SHA256.hexdigest(string)[0, DIGEST_LENGTH]

    def bundle_digest_of(kind, fresh)
      hexdigest(members(kind).map { |asset| "#{asset.name}:#{digest_of(asset, fresh)}" }.join("\n"))
    end

    # An asset's text as served from +base_dir+, the directory of its URL under
    # {PREFIX}: its own for the asset, '.' in a bundle.
    def body_of(asset, base_dir, fresh = watching?)
      body = asset.read
      asset.kind == :css && asset.file? ? rewrite_css(asset, body, base_dir, fresh) : body
    end

    # +refs+, if given, collects each file it references, with its digest.
    def rewrite_css(asset, css, base_dir, fresh, refs = nil)
      dir = File.dirname(asset.source_path)
      css.gsub(CSS_URL) do
        original, quote, ref = Regexp.last_match.to_a
        next original if ref.match?(EXTERNAL_REF)

        ref_path, suffix = ref.split(/(?=[?#])/, 2)
        target = file_at(File.expand_path(ref_path, dir))
        next original unless target

        digest = digest_of(target, fresh)
        refs&.push([target, digest])
        relative = Pathname(target.digested_name(digest)).relative_path_from(Pathname(base_dir))
        "url(#{quote}#{relative}#{suffix}#{quote})"
      end
    end

    def file_at(source_path) = all.find { |asset| asset.kind == :file && asset.source_path == source_path }

    # The bundle's text, for its +digest+, or +nil+ if its assets changed while
    # it was built, so it isn't served or cached under a digest it doesn't match.
    def bundle_body(kind, digest)
      cached = @lock.synchronize { @bundles[kind] }
      return cached.last if cached && cached.first == digest

      body = members(kind).map { |asset| body_of(asset, '.', false) }.join(BUNDLE_SEPARATORS.fetch(kind))
      return unless bundle_digest_of(kind, true) == digest

      @lock.synchronize { @bundles[kind] = [digest, body] }
      body
    end

    def serve_bundle(env, kind, requested)
      return NOT_FOUND if members(kind).empty?

      current = bundle_digest_of(kind, true)
      return redirect(env, bundle_path(kind)) unless requested == current

      type = Rack::Mime.mime_type(".#{kind}")
      respond(env, current, "#{type}; charset=utf-8") { bundle_body(kind, current) } ||
        redirect(env, bundle_path(kind))
    end

    # A stylesheet or script from a file is digested from the very text that's
    # served.
    def serve_asset(env, asset, requested)
      body = nil
      current =
        if asset.kind == :css && asset.file?
          stamp = asset.stamp
          refs = []
          body = rewrite_css(asset, asset.read, File.dirname(asset.name), true, refs)
          asset.cache(hexdigest(body), CssStamp.new(file: stamp, refs:))
        elsif asset.kind == :js && asset.file?
          stamp = asset.stamp
          body = asset.read
          asset.cache(hexdigest(body), stamp)
        else
          digest_of(asset, true)
        end
      return redirect(env, path(asset.name)) unless requested == current

      return respond(env, current, asset.content_type, file: asset.source_path) if asset.kind == :file

      respond(env, current, asset.content_type) { body || asset.read }
    end

    # Streams +file+, or else serves the text the block returns, or returns
    # +nil+ if it returns +nil+. A request whose +If-None-Match+ is the digest
    # gets a 304, without reading either.
    def respond(env, digest, content_type, file: nil)
      etag = %("#{digest}")
      headers = { 'cache-control' => IMMUTABLE, 'etag' => etag }
      return [304, headers, []] if env['HTTP_IF_NONE_MATCH'] == etag

      if file
        size = File.size(file)
        body = Rack::Files::Iterator.new(file, [0..(size - 1)], mime_type: content_type, size:)
      else
        return unless (text = yield)

        size = text.bytesize
        body = [text]
      end
      headers['content-type'] = content_type
      headers['content-length'] = size.to_s
      [200, headers, env[Rack::REQUEST_METHOD] == 'HEAD' ? [] : body]
    end

    def redirect(env, path)
      [302, { 'location' => "#{env[Rack::SCRIPT_NAME]}#{path}", 'cache-control' => 'no-cache' }, []]
    end
  end
end

require_relative 'assets/watcher'
require_relative 'assets/live_reload'

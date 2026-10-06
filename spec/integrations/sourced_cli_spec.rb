# frozen_string_literal: true

require 'tmpdir'
require 'sidereal/integrations/sourced'
require 'sidereal/integrations/sourced/cli'

RSpec.describe Sidereal::Integrations::Sourced::CLI::TopologyTree do
  SourcedCLISpecNode = Struct.new(:type, :id, :name, :group_id, :produces, :consumes, :schema, keyword_init: true)

  def command(id, name, produces: [], schema: nil)
    SourcedCLISpecNode.new(type: 'command', id:, name:, produces:, schema:)
  end

  def event(id, name, schema: nil) = SourcedCLISpecNode.new(type: 'event', id:, name:, produces: [], schema:)

  def automation(id, name, consumes:, produces: [], group: 'orders')
    SourcedCLISpecNode.new(type: 'automation', id:, name:, group_id: group, consumes:, produces:)
  end

  def read_model(id, name, consumes:, produces: [])
    SourcedCLISpecNode.new(type: 'readmodel', id:, name:, group_id: name, consumes:, produces:)
  end

  def tree(*nodes) = described_class.new(nodes).lines

  it 'follows commands to events, automations and the commands they dispatch' do
    lines = tree(
      command('orders.place', 'Place', produces: ['orders.placed']),
      command('orders.ship', 'Ship', produces: ['orders.shipped']),
      automation('orders.placed-aut', 'reaction(Placed)', consumes: ['orders.placed'], produces: ['orders.ship']),
      event('orders.placed', 'Placed'),
      event('orders.shipped', 'Shipped')
    )

    expect(lines).to eq([
      'command orders.place  Place',
      '└─ event orders.placed  Placed',
      '   └─ automation reaction(Placed)  in orders',
      '      └─ command orders.ship  Ship',
      '         └─ event orders.shipped  Shipped'
    ])
  end

  it 'lists read models under the events they consume, with their own automations' do
    lines = tree(
      command('orders.place', 'Place', produces: %w[orders.placed orders.priced]),
      read_model('orders-rm', 'orders_projector', consumes: %w[orders.placed orders.priced], produces: ['orders-aut']),
      automation('orders-aut', 'reaction(orders_projector)', consumes: ['orders-rm'], group: 'orders_projector'),
      event('orders.placed', 'Placed'),
      event('orders.priced', 'Priced')
    )

    expect(lines).to eq([
      'command orders.place  Place',
      '├─ event orders.placed  Placed',
      '│  └─ read model orders_projector',
      '│     └─ automation reaction(orders_projector)  in orders_projector',
      '└─ event orders.priced  Priced',
      '   └─ read model orders_projector (see above)'
    ])
  end

  it 'expands a cycle once' do
    lines = tree(
      command('ping', 'Ping', produces: ['pinged']),
      automation('pinged-aut', 'reaction(Pinged)', consumes: ['pinged'], produces: ['ping']),
      event('pinged', 'Pinged')
    )

    expect(lines).to eq([
      'command ping  Ping',
      '└─ event pinged  Pinged',
      '   └─ automation reaction(Pinged)  in orders',
      '      └─ command ping  Ping (see above)'
    ])
  end

  it 'starts from events no command produces' do
    lines = tree(
      read_model('stock-rm', 'stock_projector', consumes: ['stock.received']),
      event('stock.received', 'Received')
    )

    expect(lines).to eq([
      'event stock.received  Received',
      '└─ read model stock_projector'
    ])
  end

  it 'adds a schema line under commands and events with schemas: true, the first time they appear' do
    schema = { 'type' => 'object' }
    nodes = [
      command('orders.place', 'Place', produces: ['orders.placed'], schema:),
      command('orders.redo', 'Redo', produces: ['orders.placed'], schema: {}),
      event('orders.placed', 'Placed', schema:)
    ]

    expect(described_class.new(nodes, schemas: true).lines).to eq([
      'command orders.place  Place',
      '│  schema {"type":"object"}',
      '└─ event orders.placed  Placed',
      '      schema {"type":"object"}',
      'command orders.redo  Redo',
      '└─ event orders.placed  Placed (see above)'
    ])
    expect(described_class.new(nodes).lines).not_to include(a_string_including('schema'))
  end

  it 'shows messages without a node of their own by type' do
    expect(tree(command('orders.place', 'Place', produces: ['orders.placed']))).to eq([
      'command orders.place  Place',
      '└─ event orders.placed'
    ])
  end
end

RSpec.describe Sidereal::Integrations::Sourced, '.setup' do
  # Sourced.config is process-global and gets mounted into Sidereal.config,
  # which the suite replaces before each example: a fresh one can be mounted.
  before do
    Sourced.reset!
    Sourced::Store::MessageCodec.reset!
    # Both registries outlive an example, and a previous one may have filled them.
    Sidereal::CLI::Sourced::COMMANDS.delete('migration')
    Sidereal::CLI::Sourced::COMMANDS.delete('topology')
    Sidereal.skills.delete('sidereal-sourced')
  end

  after { Sourced.reset! }

  it 'registers the commands that need Sourced loaded, beside the built-in install' do
    Sidereal.config.use described_class

    expect(Sidereal::CLI::Sourced::COMMANDS)
      .to include('migration' => Sidereal::Integrations::Sourced::CLI::Migration,
                  'topology' => Sidereal::Integrations::Sourced::CLI::Topology,
                  'install' => Sidereal::CLI::Sourced::Install)
  end

  it 'registers the sidereal-sourced skill' do
    Sidereal.config.use described_class

    skill = File.read(File.join(Sidereal.skills['sidereal-sourced'], 'SKILL.md'))
    expect(skill).to include('name: sidereal-sourced', 'bin/sid sourced topology')
  end

  it 'registers neither until the app configures the integration' do
    expect(Sidereal::CLI::Sourced::COMMANDS).not_to have_key('migration')
    expect(Sidereal::CLI::Sourced::COMMANDS).not_to have_key('topology')
    expect(Sidereal.skills['sidereal-sourced']).to be_nil
  end
end

RSpec.describe Sidereal::CLI, '.load_app' do
  around do |example|
    pwd = Dir.pwd
    Dir.mktmpdir('sid-load-app') do |dir|
      @dir = dir
      example.run
    end
  ensure
    Dir.chdir(pwd)
  end

  after { %w[console commands skills].each { |name| Sidereal::CLI.registry.delete(name) } }

  # A unique directory per example, so `require` doesn't skip the second boot.rb.
  def boot!(body)
    File.write(File.join(@dir, 'boot.rb'), body)
    Sidereal::CLI.load_app(@dir)
  end

  it "registers the commands that need an app, and loads the app's boot.rb" do
    boot!("SidLoadAppMarker = :loaded\n")

    expect(Sidereal::CLI.registry).to include(
      'console' => Sidereal::CLI::AppConsole,
      'commands' => Sidereal::CLI::Commands,
      'skills' => Sidereal::CLI::SkillsCommand
    )
    expect(SidLoadAppMarker).to eq(:loaded)
    expect(Sidereal::CLI.app_root).to eq(File.expand_path(@dir))
  end

  it 'builds nothing, so nothing is connected to yet' do
    boot!("Sidereal.config.declare('spec.thing', Object)\nSidereal.config.config!('spec.thing') { raise 'built!' }\n")

    expect(Sidereal.config.boot_status).to eq(:open)
  end

  describe 'an app that fails to load' do
    it 'warns and keeps the commands that do not need the app' do
      expect { boot!("raise 'boom'\n") }.to output(/failed to load.*boom/m).to_stderr

      expect(Sidereal::CLI.registry).to include('console', 'commands', 'skills')
    end

    it 're-raises from boot_app!, so a command that needs the app still fails loudly' do
      expect { boot!("raise 'boom'\n") }.to output.to_stderr

      expect { Sidereal::CLI.boot_app! }.to raise_error(RuntimeError, 'boom')
    end
  end
end

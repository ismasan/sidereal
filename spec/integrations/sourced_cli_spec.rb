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

RSpec.describe Sidereal::Integrations::Sourced::CLI::Groups::List do
  # The command reads one thing — the store's stats — so it is driven against
  # those rather than a booted app, the way the topology specs drive the tree.
  def list(groups, max_position: 42)
    stats = Sourced::Stats.new(max_position:, groups:)
    allow(Sidereal::CLI).to receive(:boot_app!)
    allow(Sidereal.config).to receive(:[]).with('sourced.store').and_return(instance_double(Sourced::Store, stats:))

    out = StringIO.new
    described_class.new([], name: 'list', output: out).call
    out.string
  end

  def group(id, status: 'active', partitions: 1, newest: 42, retry_at: nil, error: {})
    { group_id: id, status:, partition_count: partitions, oldest_processed: 1,
      newest_processed: newest, retry_at:, error_context: error }
  end

  it 'lists each group with its status, partitions and how far behind it is' do
    out = list([group('Todos', partitions: 3, newest: 40)])

    expect(out).to include('Group', 'Status', 'Partitions', 'Position', 'Lag')
    expect(out).to match(/^Todos\s+active\s+3\s+40\s+2$/)
  end

  it 'counts the groups and says where the store is' do
    expect(list([group('A'), group('B')])).to start_with("2 groups, store at position 42")
    expect(list([group('A')])).to start_with('1 group, ')
  end

  it 'says so when no group has been registered yet' do
    expect(list([])).to include('No consumer groups yet')
  end

  # The table can't carry why a group stopped, so it goes underneath.
  it 'names the error behind a failed group' do
    out = list([group('Broken', status: 'failed',
                      error: { exception_class: 'RuntimeError', exception_message: 'boom' })])

    expect(out).to match(/^Broken\s+failed/)
    expect(out).to include('Broken: RuntimeError: boom')
  end

  # `groups stop --message` keeps the operator's words in the same field an
  # exception uses, so a stopped group would otherwise print a blank line.
  it 'shows why a group was stopped, in the operator\'s own words' do
    out = list([group('Paused', status: 'stopped', error: { message: 'draining for deploy' })])

    expect(out).to include('Paused: draining for deploy')
  end

  it 'says whatever the context holds rather than nothing' do
    out = list([group('Odd', status: 'stopped', error: { note: 'something else' })])

    expect(out).to match(/Odd: .*something else/)
  end

  it 'leaves the retry column out until a group is waiting to retry' do
    expect(list([group('A')])).not_to include('Retry at')

    out = list([group('A', retry_at: Time.new(2026, 4, 1, 12, 30, 0))])

    expect(out).to include('Retry at', '2026-04-01 12:30:00')
  end
end

RSpec.describe Sidereal::Integrations::Sourced::CLI::Groups::Stop do
  let(:store) { instance_double(Sourced::Store, stats: Sourced::Stats.new(max_position: 9, groups:)) }
  let(:groups) { [{ group_id: 'Todos', status: 'active', partition_count: 1, oldest_processed: 1,
                    newest_processed: 9, retry_at: nil, error_context: {} }] }

  let(:router) { instance_double(Sourced::Router) }

  def stop(*arguments)
    allow(Sidereal::CLI).to receive(:boot_app!)
    allow(Sidereal.config).to receive(:[]).with('sourced.store').and_return(store)
    allow(Sidereal.config).to receive(:[]).with('sourced.router').and_return(router)

    out = StringIO.new
    described_class.new(arguments, name: 'stop', output: out).call
    out.string
  end

  it 'stops the named group' do
    expect(router).to receive(:stop_consumer_group).with('Todos', nil)

    expect(stop('Todos')).to include('stopped', 'Todos')
  end

  it 'keeps the reason with it' do
    expect(router).to receive(:stop_consumer_group).with('Todos', 'draining')

    stop('Todos', '--message', 'draining')
  end

  # The store knows which groups exist and names them; this only has to keep
  # that out of a backtrace, since Application.call prints a CLI::Error.
  it "turns the store's unknown-group error into a command-line error" do
    allow(router).to receive(:stop_consumer_group)
      .and_raise(Sourced::Router::UnregisteredReactorError.new('Todoz', []))

    expect { stop('Todoz') }
      .to raise_error(Sidereal::CLI::Error, /group_id "Todoz" is not registered with this router/)
  end

  it 'leaves an already-stopped group alone' do
    groups.first[:status] = 'stopped'
    expect(router).not_to receive(:stop_consumer_group)

    expect(stop('Todos')).to include('already stopped')
  end

  it 'needs a group to stop' do
    expect { stop }.to raise_error(Sidereal::CLI::Error, /Name a group/)
  end
end

RSpec.describe Sidereal::Integrations::Sourced::CLI::Groups::Start do
  let(:store) { instance_double(Sourced::Store, stats: Sourced::Stats.new(max_position: 9, groups:)) }
  let(:groups) { [{ group_id: 'Todos', status: 'stopped', partition_count: 1, oldest_processed: 1,
                    newest_processed: 4, retry_at: nil, error_context: { message: 'draining' } }] }

  let(:router) { instance_double(Sourced::Router) }

  def start(*arguments)
    allow(Sidereal::CLI).to receive(:boot_app!)
    allow(Sidereal.config).to receive(:[]).with('sourced.store').and_return(store)
    allow(Sidereal.config).to receive(:[]).with('sourced.router').and_return(router)

    out = StringIO.new
    described_class.new(arguments, name: 'start', output: out).call
    out.string
  end

  it 'starts a stopped group' do
    expect(router).to receive(:start_consumer_group).with('Todos')

    expect(start('Todos')).to include('started', 'Todos')
  end

  # The case that matters: a group that stopped on an error.
  it 'starts a failed group' do
    groups.first[:status] = 'failed'
    expect(router).to receive(:start_consumer_group).with('Todos')

    expect(start('Todos')).to include('started')
  end

  it 'leaves a running group alone' do
    groups.first[:status] = 'active'
    expect(router).not_to receive(:start_consumer_group)

    expect(start('Todos')).to include('already running')
  end

  it "turns the store's unknown-group error into a command-line error" do
    allow(router).to receive(:start_consumer_group)
      .and_raise(Sourced::Router::UnregisteredReactorError.new('Todoz', []))

    expect { start('Todoz') }
      .to raise_error(Sidereal::CLI::Error, /group_id "Todoz" is not registered with this router/)
  end

  it 'needs a group to start' do
    expect { start }.to raise_error(Sidereal::CLI::Error, %r{groups start Todos})
  end
end

RSpec.describe Sidereal::Integrations::Sourced::CLI::Groups::Reset do
  let(:store) { instance_double(Sourced::Store, stats: Sourced::Stats.new(max_position: 9, groups: [])) }
  let(:reactor) { double('reactor', group_id: 'Widgets', exclusive?: false) }
  let(:router) { double('router', reactors: [reactor]) }

  def reset(*arguments, tty: false, answer: "n\n")
    allow(Sidereal::CLI).to receive(:boot_app!)
    allow(Sidereal.config).to receive(:[]).with('sourced.store').and_return(store)
    allow(Sidereal.config).to receive(:[]).with('sourced.router').and_return(router)
    allow($stdin).to receive(:tty?).and_return(tty)
    allow($stdin).to receive(:gets).and_return(answer)

    out = StringIO.new
    described_class.new(arguments, name: 'reset', output: out).call
    out.string
  end

  it 'resets the group when confirmed' do
    expect(router).to receive(:reset_consumer_group).with('Widgets')

    expect(reset('Widgets', '--yes')).to include('reset', 'Widgets')
  end

  # Sourced skips a reset for an exclusive group, but decides that from the
  # groups registered in its own process — which a CLI never does.
  it 'refuses a group that deletes its messages as it acks them' do
    allow(reactor).to receive(:exclusive?).and_return(true)
    expect(router).not_to receive(:reset_consumer_group)

    expect { reset('Widgets', '--yes') }
      .to raise_error(Sidereal::CLI::Error, /exclusively.*nothing to replay/m)
  end

  it 'asks first, and does nothing when the answer is no' do
    expect(router).not_to receive(:reset_consumer_group)

    out = reset('Widgets', tty: true, answer: "n\n")

    expect(out).to include('read the whole store again', 'Reset it? [y/N]', 'Not reset.')
  end

  it 'goes ahead when the answer is yes' do
    expect(router).to receive(:reset_consumer_group).with('Widgets')

    expect(reset('Widgets', tty: true, answer: "y\n")).to include('reset')
  end

  # Never silently destructive in a script or a pipe.
  it 'refuses to guess when there is nobody to ask' do
    expect(router).not_to receive(:reset_consumer_group)

    expect { reset('Widgets') }.to raise_error(Sidereal::CLI::Error, /Pass --yes to confirm/)
  end

  it "turns the store's unknown-group error into a command-line error" do
    allow(router).to receive(:reset_consumer_group)
      .and_raise(Sourced::Store::UnknownConsumerGroupError.new('Nope', ['Widgets']))

    expect { reset('Nope', '--yes') }.to raise_error(Sidereal::CLI::Error, /No consumer group "Nope"/)
  end

  it 'needs a group to reset' do
    expect { reset }.to raise_error(Sidereal::CLI::Error, %r{groups reset Todos})
  end
end

RSpec.describe Sidereal::Integrations::Sourced, '.setup' do
  # Sourced.config is process-global and gets mounted into Sidereal.config,
  # which the suite replaces before each example: a fresh one can be mounted.
  before do
    Sourced.reset!
    Sourced::Store::MessageCodec.reset!
    # Both registries outlive an example, and a previous one may have filled them.
    Sidereal::CLI::Sourced::COMMANDS.delete('groups')
    Sidereal::CLI::Sourced::COMMANDS.delete('migration')
    Sidereal::CLI::Sourced::COMMANDS.delete('topology')
    Sidereal.skills.delete('sidereal-sourced')
  end

  after { Sourced.reset! }

  it 'registers the commands that need Sourced loaded, beside the built-in install' do
    Sidereal.config.use described_class

    expect(Sidereal::CLI::Sourced::COMMANDS)
      .to include('groups' => Sidereal::Integrations::Sourced::CLI::Groups,
                  'migration' => Sidereal::Integrations::Sourced::CLI::Migration,
                  'topology' => Sidereal::Integrations::Sourced::CLI::Topology,
                  'install' => Sidereal::CLI::Sourced::Install)
  end

  it 'registers the sidereal-sourced skill' do
    Sidereal.config.use described_class

    skill = File.read(File.join(Sidereal.skills['sidereal-sourced'], 'SKILL.md'))
    expect(skill).to include('name: sidereal-sourced', 'bin/sid sourced topology')
  end

  it 'registers neither until the app configures the integration' do
    expect(Sidereal::CLI::Sourced::COMMANDS).not_to have_key('groups')
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

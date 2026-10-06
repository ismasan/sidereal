# frozen_string_literal: true

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

RSpec.describe Sidereal::CLI, '.load_app' do
  after do
    %w[console commands skills sourced].each { |name| Sidereal::CLI.registry.delete(name) }
  end

  it 'registers the sourced commands when the bundle includes sourced' do
    Sidereal::CLI.load_app(Dir.pwd)

    expect(Sidereal::CLI.registry['sourced']).to eq(Sidereal::Integrations::Sourced::CLI::Namespace)
  end

  it 'leaves them out otherwise' do
    allow(Gem).to receive(:loaded_specs).and_return({})

    Sidereal::CLI.load_app(Dir.pwd)

    expect(Sidereal::CLI.registry).not_to have_key('sourced')
  end
end

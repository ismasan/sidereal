# frozen_string_literal: true

require 'sidereal/cli'

CLICatalogAdd = Sidereal::Message.define('cli_catalog.add')
CLICatalogRemove = Sidereal::Message.define('cli_catalog.remove')
CLICatalogArchive = Sidereal::Message.define('cli_catalog.archive')
CLICatalogWebOnly = Sidereal::Message.define('cli_catalog.web_only')

RSpec.describe Sidereal::CLI::Commands::Catalog do
  let(:commander) do
    Class.new(Sidereal::Commander) do
      command CLICatalogAdd do |_cmd|
      end
    end
  end

  let(:app) do
    Class.new(Sidereal::App) do
      handle CLICatalogAdd, CLICatalogWebOnly

      command CLICatalogRemove do |_cmd|
      end
    end
  end

  # Duck-typed Sourced decider: a reactor that declares its commands.
  let(:decider) do
    Class.new do
      def self.handled_commands = [CLICatalogArchive, CLICatalogAdd]
      def self.name = 'Todos'
    end
  end

  def entry(entries, type) = entries.find { |e| e.type == type }

  it "lists commands from commanders, including an app's built-in one" do
    entries = described_class.new(apps: [app], commanders: [commander, app.commander]).entries

    expect(entry(entries, 'cli_catalog.add').handlers).to eq([commander])
    expect(entry(entries, 'cli_catalog.remove').handlers).to eq([app.commander])
  end

  it 'lists commands handled by Sourced deciders' do
    entries = described_class.new(apps: [], commanders: [commander], sourced_reactors: [decider]).entries

    expect(entry(entries, 'cli_catalog.archive').handlers).to eq([decider])
    expect(entry(entries, 'cli_catalog.add').handlers).to eq([commander, decider])
  end

  it 'skips Sidereal commanders registered as Sourced reactors' do
    entries = described_class.new(apps: [], commanders: [commander], sourced_reactors: [commander]).entries

    expect(entry(entries, 'cli_catalog.add').handlers).to eq([commander])
  end

  it 'marks commands the web accepts, and lists them even without a handler' do
    entries = described_class.new(apps: [app], commanders: [commander]).entries

    expect(entry(entries, 'cli_catalog.add')).to be_web
    expect(entry(entries, 'cli_catalog.web_only')).to have_attributes(web?: true, handlers: [])
    expect(entry(entries, 'cli_catalog.remove')).to be_nil
  end

  it 'sorts by command type' do
    entries = described_class.new(apps: [app], commanders: [commander, app.commander],
                                  sourced_reactors: [decider]).entries

    expect(entries.map(&:type)).to eq(%w[
      cli_catalog.add cli_catalog.archive cli_catalog.remove cli_catalog.web_only
    ])
  end
end

CLISchemaOrder = Sidereal::Message.define('cli_schema.order') do
  attribute :dish, Sidereal::Types::String.present
  attribute :quantity, Sidereal::Types::Integer.nullable
  attribute :size, Sidereal::Types::String.options(%w[small large]).default('small')
  attribute? :notes, Sidereal::Types::String
  attribute :extras, Sidereal::Types::Array[Sidereal::Types::String]
  attribute :table do
    attribute :number, Sidereal::Types::Integer
  end
  attribute :lines, Sidereal::Types::Array do
    attribute :sku, Sidereal::Types::String
  end
end

CLISchemaPing = Sidereal::Message.define('cli_schema.ping')

RSpec.describe Sidereal::CLI::Commands::SchemaTable do
  def rows_for(message) = described_class.new(message::Payload.to_json_schema).rows

  it 'lists attributes with type, required, default and notes' do
    expect(rows_for(CLISchemaOrder)).to eq([
      ['dish', 'string', 'yes', '', ''],
      ['quantity', 'integer | null', 'yes', '', ''],
      ['size', 'string', 'yes', '"small"', 'one of: "small", "large"'],
      ['notes', 'string', '', '', ''],
      ['extras', 'array of string', 'yes', '', ''],
      ['table', 'object', 'yes', '', ''],
      ['table.number', 'integer', 'yes', '', ''],
      ['lines', 'array of object', 'yes', '', ''],
      ['lines[].sku', 'string', 'yes', '', '']
    ])
  end

  it 'has no rows for an empty payload' do
    expect(rows_for(CLISchemaPing)).to eq([])
  end

  it 'lists keywords without a column of their own as notes' do
    schema = {
      'type' => 'object',
      'properties' => { 'age' => { 'type' => 'integer', 'description' => 'In years', 'minimum' => 0 } }
    }

    expect(described_class.new(schema).rows).to eq([['age', 'integer', '', '', 'In years; minimum: 0']])
  end
end

RSpec.describe Sidereal::CLI::Commands, '.print_table' do
  def print_table(rows, **options)
    io = StringIO.new
    terminal = Console::Terminal.for(io)
    described_class.print_table(terminal, %w[Name Type Notes], rows, **options)
    io.string
  end

  it 'aligns columns' do
    expect(print_table([%w[a string x], %w[longer int y]])).to eq(<<~TEXT)
      Name    Type    Notes
      a       string  x
      longer  int     y
    TEXT
  end

  it 'leaves out empty columns after the first `keep`' do
    expect(print_table([['a', 'string', '']], keep: 2)).to eq("Name  Type\na     string\n")
  end
end

RSpec.describe Sidereal::CLI::Commands::Arguments do
  subject(:arguments) { described_class.new(CLISchemaOrder::Payload.to_json_schema) }

  it 'reads --name value and --name=value' do
    expect(arguments.parse(%w[--dish Pizza --quantity=2])).to eq(dish: 'Pizza', quantity: '2')
  end

  it 'reads a bare flag as true, before another attribute or at the end' do
    expect(arguments.parse(%w[--dish --quantity 2])).to eq(dish: 'true', quantity: '2')
    expect(arguments.parse(%w[--quantity 2 --dish])).to eq(quantity: '2', dish: 'true')
  end

  it 'keeps values that start with a single dash' do
    expect(arguments.parse(%w[--quantity -2])).to eq(quantity: '-2')
  end

  it 'builds nested attributes from dotted names' do
    expect(arguments.parse(%w[--table.number 4])).to eq(table: { number: '4' })
  end

  it 'collects array attributes, even from a single value' do
    expect(arguments.parse(%w[--extras cheese])).to eq(extras: ['cheese'])
    expect(arguments.parse(%w[--extras cheese --extras olives])).to eq(extras: %w[cheese olives])
  end

  it 'rejects unknown attributes, naming the known ones' do
    expect { arguments.parse(%w[--dsh Pizza]) }
      .to raise_error(Sidereal::CLI::Error, /Unknown attribute --dsh\. Expected: --dish, --quantity/)
    expect { arguments.parse(%w[--table.nmber 4]) }
      .to raise_error(Sidereal::CLI::Error, 'Unknown attribute --table.nmber. Expected: --table.number')
  end

  it 'rejects an attribute given twice' do
    expect { arguments.parse(%w[--dish a --dish b]) }
      .to raise_error(Sidereal::CLI::Error, '--dish is given more than once')
  end

  it 'rejects values without an attribute name' do
    expect { arguments.parse(%w[Pizza]) }
      .to raise_error(Sidereal::CLI::Error, 'Expected an attribute like --name, got "Pizza"')
  end

  it 'says so when the command has no attributes' do
    expect { described_class.new(CLISchemaPing::Payload.to_json_schema).parse(%w[--x 1]) }
      .to raise_error(Sidereal::CLI::Error, 'Unknown attribute --x. This command has no attributes.')
  end
end

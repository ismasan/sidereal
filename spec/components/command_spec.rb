# frozen_string_literal: true

require 'spec_helper'

CommandSpecAddItem = Sidereal::Message.define('command_spec.add_item') do
  attribute :title, Sidereal::Types::String.present
end

CommandSpecBookCourse = Sidereal::Message.define('command_spec.book_course') do
  attribute :course_name, Sidereal::Types::String.present
  attribute :seats, Sidereal::Types::Integer
  attribute :starts_on, Sidereal::Types::Date
  attribute :published, Sidereal::Types::Boolean
end

RSpec.describe Sidereal::Components::Command do
  # Values are encoded through the codec of the app that exposed the command, so
  # a form can only be rendered for a `handle`-ed type.
  let(:app) do
    Class.new(Sidereal::App) { handle CommandSpecAddItem, CommandSpecBookCourse }
  end

  # While rendering, the component calls context.url(@href) and
  # context.forms_codec. Stand in for both.
  let(:context) do
    Class.new do
      def initialize(forms_codec) = @forms_codec = forms_codec
      def url(addr = nil, *) = addr.to_s
      attr_reader :forms_codec
    end.new(app.forms_codec)
  end

  def render(*args, &block)
    block ||= proc { |f| f.text_field :title }
    described_class.new(*args).call(context:, &block)
  end

  it 'derives a deterministic id prefix from the command type' do
    html = render(CommandSpecAddItem)
    # type 'command_spec.add_item' sanitized + default key 'cmd'
    expect(html).to include('name="command[_cid]" value="command_spec_add_item-cmd"')
    expect(html).to include('id="command_spec_add_item-cmd-title"')
    expect(html).to include('id="command_spec_add_item-cmd-title-wrapper"')
    expect(html).to include('id="command_spec_add_item-cmd-title-errors"')
  end

  it 'sanitizes dots out of generated ids (the dotted type stays in command[type])' do
    html = render(CommandSpecAddItem)
    ids = html.scan(/id="([^"]*)"/).flatten
    expect(ids).not_to be_empty
    expect(ids).to all(satisfy { |id| !id.include?('.') })
    # the real dotted type is still submitted as the command type
    expect(html).to include('name="command[type]" value="command_spec.add_item"')
  end

  it 'produces identical ids across separate renders of the same form' do
    expect(render(CommandSpecAddItem)).to eq(render(CommandSpecAddItem))
  end

  it 'uses :key to disambiguate multiple instances of the same command type' do
    one = render(CommandSpecAddItem, key: 42)
    two = render(CommandSpecAddItem, key: 99)

    expect(one).to include('id="command_spec_add_item-42-title"')
    expect(two).to include('id="command_spec_add_item-99-title"')
    expect(one).not_to eq(two)
  end

  it 'does not leak :key as an attribute on the form element' do
    html = render(CommandSpecAddItem, key: 42)
    expect(html).to match(/<form[^>]*>/)
    expect(html[/<form[^>]*>/]).not_to include('key=')
  end

  # Stand in for a Sourced::Machine::Configuration, which is its own
  # #to_machine_config, and for a machine instance, which answers with its own.
  CommandSpecConfiguration = Data.define(:handled_commands, :available_commands, :value) do
    def to_machine_config = self
  end
  CommandSpecMachine = Data.define(:to_machine_config)

  describe 'inside with_machine' do
    let(:machine) { CommandSpecConfiguration.new(Set[CommandSpecAddItem, CommandSpecBookCourse], Set[CommandSpecAddItem], :placed) }

    let(:wrapping) do
      Class.new(Sidereal::Components::BaseComponent) do
        def initialize(machine, content)
          @machine = machine
          @content = content
        end

        def view_template = with_machine(@machine) { instance_exec(&@content) }
      end
    end

    def render_in(&content) = wrapping.new(machine, content).call(context:)

    it 'renders a form for a command the machine accepts' do
      html = render_in { command(CommandSpecAddItem) { |f| f.text_field :title } }
      expect(html).to include('value="command_spec.add_item"')
    end

    it "raises for a command the machine handles, but doesn't accept now" do
      expect { render_in { command(CommandSpecBookCourse) { |f| f.text_field :course_name } } }.to raise_error(
        Sidereal::CommandNotAvailableError,
        "CommandSpecBookCourse isn't available at :placed. Available: CommandSpecAddItem"
      )
    end

    it "renders a form for a command the machine doesn't handle" do
      foreign = CommandSpecConfiguration.new(Set[CommandSpecAddItem], Set[CommandSpecAddItem], :placed)
      html = wrapping.new(foreign, proc { command(CommandSpecBookCourse) { |f| f.text_field :course_name } }).call(context:)

      expect(html).to include('value="command_spec.book_course"')
    end

    it "names a machine instance's state, from its configuration" do
      instance = CommandSpecMachine.new(CommandSpecConfiguration.new(Set[CommandSpecAddItem], Set[], :done))

      expect { wrapping.new(instance, proc { command(CommandSpecAddItem) }).call(context:) }.to raise_error(
        Sidereal::CommandNotAvailableError, "CommandSpecAddItem isn't available at :done. Available: nothing"
      )
    end

    it 'checks nothing outside it, and restores the previous machine after it' do
      expect { render_in { raise 'boom' } }.to raise_error('boom')
      expect(Sidereal::Components::BaseComponent.current_machine).to be_nil
      expect(render(CommandSpecBookCourse)).to include('value="command_spec.book_course"')
    end

    it 'raises for anything without to_machine_config' do
      component = Class.new(Sidereal::Components::BaseComponent) do
        def view_template = with_machine(Object.new) {}
      end
      expect { component.new.call(context:) }.to raise_error(NoMethodError, /to_machine_config/)
    end

    describe '.with_machine' do
      let(:component) do
        Class.new(Sidereal::Components::BaseComponent) do
          with_machine { @machine }

          def initialize(machine, command_class)
            @machine = machine
            @command_class = command_class
          end

          def view_template
            command(@command_class) { |f| f.text_field :title }
          end
        end
      end

      it 'wraps the whole template, in subclasses too' do
        expect(Class.new(component).new(machine, CommandSpecAddItem).call(context:)).to include('command_spec.add_item')
        expect { Class.new(component).new(machine, CommandSpecBookCourse).call(context:) }
          .to raise_error(Sidereal::CommandNotAvailableError)
        expect(Sidereal::Components::BaseComponent.current_machine).to be_nil
      end
    end
  end

  # The mirror of decoding: a command holds Ruby values, an <input> can only
  # hold a String, so the app's FormsCodec encodes at that boundary.
  describe 'rendering a command instance' do
    let(:command) do
      CommandSpecBookCourse.new(
        payload: { course_name: 'Ruby 101', seats: 30, starts_on: Date.new(2026, 9, 1), published: true }
      )
    end

    def render_course(cmd, &block)
      block ||= proc do |f|
        f.text_field :course_name
        f.number_field :seats
        f.check_box :published
      end
      described_class.new(cmd).call(context:, &block)
    end

    it 'renders each value as the string the codec decodes back' do
      html = render_course(command)

      expect(html).to include('value="Ruby 101"')
      expect(html).to include('value="30"')
    end

    # <input type="date"> submits YYYY-MM-DD, which is what the codec's
    # DateEncoder both reads and writes — so a Types::Date round-trips as-is.
    it 'renders a date_field in the form the browser submits' do
      html = render_course(command) { |f| f.date_field :starts_on }

      expect(html).to include('type="date"')
      expect(html).to include('value="2026-09-01"')
    end

    it 'renders no value at all for a blank command' do
      html = render_course(CommandSpecBookCourse)

      expect(html[/<input[^>]*name="command\[payload\]\[course_name\]"[^>]*>/]).not_to include('value=')
    end

    describe 'text_area' do
      it 'renders the encoded value as the element content, inside the error wrapper' do
        html = render_course(command) { |f| f.text_area :course_name, rows: 4 }

        expect(html).to include('id="command_spec_book_course-cmd-course_name-wrapper"')
        expect(html).to include(
          '<textarea rows="4" id="command_spec_book_course-cmd-course_name" ' \
          'name="command[payload][course_name]">Ruby 101</textarea>'
        )
        expect(html).to include('id="command_spec_book_course-cmd-course_name-errors"')
      end

      it 'renders an empty element for a blank command' do
        html = render_course(CommandSpecBookCourse) { |f| f.text_area :course_name }

        expect(html).to include('name="command[payload][course_name]"></textarea>')
      end
    end

    it 'encodes payload_fields values, so a Date reaches the browser decodable' do
      html = render_course(command) { |f| f.payload_fields(starts_on: Date.new(2026, 9, 1)) }

      expect(html).to include('value="2026-09-01"')
    end

    # The common case: values the loop supplies, on a command that holds nothing.
    it 'encodes payload_fields values on an otherwise blank command' do
      html = render_course(CommandSpecBookCourse) { |f| f.payload_fields(seats: 30, published: true) }

      expect(html).to include('name="command[payload][seats]" value="30"')
      expect(html).to include('name="command[payload][published]" value="true"')
    end

    # #with_payload drops keys the payload does not declare, which would render a
    # silently empty hidden field.
    it 'raises for a payload_fields key the command does not declare' do
      expect {
        render_course(command) { |f| f.payload_fields(nope: 'x') }
      }.to raise_error(ArgumentError, /command_spec\.book_course declares no payload attribute nope/)
    end

    it 'exposes the command so form blocks can branch on its Ruby values' do
      captured = nil
      render_course(command) { |f| captured = f.command.payload.published }

      expect(captured).to be(true)
    end

    describe 'check_box' do
      # An unchecked box submits nothing, so a hidden '0' shares its name and
      # Rack's last-value-wins gives the codec a string either way.
      it 'pairs the checkbox with a hidden 0' do
        html = render_course(command)

        expect(html).to include('<input type="hidden" name="command[payload][published]" value="0">')
        expect(html).to include('value="1"')
        expect(html).to match(/type="checkbox"/)
      end

      it 'is checked from the Ruby boolean, not the encoded string' do
        checked = render_course(command)
        unchecked = render_course(command.with_payload(published: false))

        expect(checked[/<input[^>]*type="checkbox"[^>]*>/]).to include('checked')
        expect(unchecked[/<input[^>]*type="checkbox"[^>]*>/]).not_to include('checked')
      end
    end
  end
end

# frozen_string_literal: true

module UI
  module CrossPost
    # Reading the cross-post machines' definitions (Machine.to_h) for the
    # pages that draw them: Sourced::UI::MachineChart, plus the machine tree
    # and its names.
    module Charts
      extend self

      include Sourced::UI::MachineChart

      # slug => machine, the root first.
      def machines = ::CrossPost.machines.to_h { [slug(it), it] }
      def machine(slug) = machines[slug]

      def slug(machine) = machine.name.delete_prefix('CrossPost::').gsub('::', '-').downcase
      def short_name(machine) = machine.name.delete_prefix('CrossPost::')

      def mounts(chart) = super.map { it.delete_prefix('CrossPost::') }
    end
  end
end

# frozen_string_literal: true

# Sourced's schema gained Message#tags (indexed alongside payload attributes)
# and a display label per consumer group (the reactor's class name, now that
# group ids are normalized to dot-separated form).
Sequel.migration do
  change do
    alter_table(:sourced_messages) do
      add_column :tags, String
    end

    alter_table(:sourced_consumer_groups) do
      add_column :label, String
    end
  end
end

# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:campaigns) do
      add_column :total_amount, Integer, default: 0, null: false
    end
  end
end

# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:comments) do
      add_column :subject_name, String, null: false, default: ''
    end
  end
end

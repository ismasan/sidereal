# frozen_string_literal: true

Sequel.migration do
  change do
    create_table(:comments) do
      String :comment_id, primary_key: true
      String :subject_id, null: false
      String :commenter_id, null: false
      String :content, null: false, text: true
      String :status, null: false
      String :vibe, null: false
      String :created_at, null: false
      String :updated_at, null: false
      index %i[subject_id status]
    end
  end
end

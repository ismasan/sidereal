# frozen_string_literal: true

# A plain GET form: choosing a subject navigates to the same page filtered by
# it. Datastar submits the form on change, so there's no button.
class SubjectPicker < Sidereal::Components::BaseComponent
  def initialize(subject:, action:)
    @subject = subject
    @action = action
  end

  def view_template
    form(action: @action, method: 'get', class: 'subject-picker') do
      label(for: 'subject-picker-select', class: 'field-label') { 'Subject' }
      select(
        id: 'subject-picker-select',
        name: 'subject_id',
        class: 'select',
        data: { 'on:change' => 'el.form.submit()' }
      ) do
        Subjects.all.each do |s|
          option(value: s.id, selected: s.id == @subject.id) { s.title }
        end
      end
    end
  end
end

# frozen_string_literal: true

# A plain GET form: choosing a subject navigates to the same page filtered by
# it, and the blank option lifts the filter. Datastar submits the form on
# change, so there's no button.
class SubjectPicker < Sidereal::Components::BaseComponent
  # @param subject [Subjects::Subject, nil] nil when no subject is selected
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
        option(value: '', selected: @subject.nil?) { 'All subjects' }
        Subjects.all.each do |s|
          option(value: s.id, selected: s.id == @subject&.id) { s.title }
        end
      end
    end
  end
end

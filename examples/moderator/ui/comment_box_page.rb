# frozen_string_literal: true

require 'securerandom'
require_relative 'components/subject_picker'

# ui:CommentBox — where the public leaves comments.
class CommentBoxPage < Sidereal::Page
  path '/'

  def self.load(params, ctx)
    # Establish the commenter's identity on first visit; `before_command`
    # stamps it onto CreateComment.
    ctx.session[:commenter_id] ||= SecureRandom.uuid
    new(
      subject: Subjects.find(params[:subject_id]) || Subjects.first,
      sent_id: params[:sent]
    )
  end

  def initialize(subject:, sent_id: nil)
    @subject = subject
    @sent_id = sent_id
  end

  def view_template
    div(id: 'comment-box-page', class: 'page page--narrow') do
      header(class: 'topbar') do
        a(href: '/', class: 'brand') { 'Moderator' }
        nav(class: 'topbar__nav') do
          a(href: "/comments?subject_id=#{@subject.id}") { 'Pipeline →' }
        end
      end

      main(class: 'panel') do
        if @sent_id
          div(class: 'notice', id: 'sent-notice') do
            strong { 'Thanks!' }
            plain ' Your comment is awaiting moderation. '
            a(href: "/comments/#{@sent_id}") { 'Watch it move through the pipeline →' }
          end
        end

        command Comment::CreateComment, class: 'comment-form', autocomplete: 'off' do |f|
          div(class: 'command-field') do
            label(for: 'comment-subject', class: 'field-label') { 'Subject' }
            select(id: 'comment-subject', name: 'command[payload][subject_id]', class: 'select') do
              Subjects.all.each do |s|
                option(value: s.id, selected: s.id == @subject.id) { s.title }
              end
            end
          end

          label do
            span(class: 'field-label') { 'Leave a comment' }
            f.text_area :content,
              class: 'textarea',
              rows: 8,
              required: true,
              placeholder: 'Be nice. Or don’t — that’s what the pipeline is for.'
          end

          div(class: 'form-actions') do
            button(type: :submit, class: 'button button--primary') { 'Submit' }
          end
        end
      end
    end
  end
end

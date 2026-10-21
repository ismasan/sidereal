# frozen_string_literal: true

RSpec.describe UI::CrossPost::ExplorerPage do
  it "lights a picked state and the states around it, with what it accepts and refuses" do
    html = described_class.build('post', 'drafting-x-valid').call

    expect(html).to match(/statechart__node--parallel is-active" id="sc-drafting"/)
    expect(html).to match(/is-active" id="sc-drafting-x-valid"/)
    expect(html).not_to match(/is-active" id="sc-drafting-x-invalid"/)
    expect(html).to include('>targets.x.deselect<', '>Submit<', '>PublishScheduled<')
  end

  it "doesn't build for an unknown machine or state" do
    expect(described_class.build('nope')).to be_nil
    expect(described_class.build('post', 'nope')).to be_nil
  end
end

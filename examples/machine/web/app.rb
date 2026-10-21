# frozen_string_literal: true

# The web app: which commands browsers may send, and pages. config.ru runs it.
#
# Commands are handled by the app's Sourced::Machines, registered in
# config/components/sourced.rb: HolidayBooking and CrossPost::Account.
# Handling one here just appends it; the machine decides it in a background
# worker, refusing any its current state doesn't accept, and the events it
# appends are published to the booking's channel, where its pages re-render.
class App < Sidereal::App
  layout UI::Layout

  # One channel per booking, so a page only hears about its own.
  channel_name do |msg|
    payload = msg.payload&.to_h || {}
    if (booking_id = payload[:booking_id]) then "bookings.#{booking_id}"
    else 'system'
    end
  end

  # The start form has no booking yet: the command's booking_id is generated
  # here, and the browser goes to the booking's page to watch it start.
  handle HolidayBooking::StartBooking do |cmd|
    dispatch cmd
    browser.redirect "/bookings/#{cmd.payload.booking_id}"
  end

  handle HolidayBooking::ChooseFlight,
         HolidayBooking::ConfirmFlight,
         HolidayBooking::ChooseHotel,
         HolidayBooking::ChooseRoom,
         HolidayBooking::ChooseBoard,
         HolidayBooking::ToggleExtra,
         HolidayBooking::FinishExtras,
         HolidayBooking::Pay,
         HolidayBooking::CancelBooking

  page UI::HomePage
  page UI::Booking::Page
  page UI::Booking::DiagramPage
  page UI::CrossPost::DefinitionsPage

  # Time travel: any tab, rendered from the first `step` messages of the
  # booking's history. Static, so nothing live replaces it. The
  # history feeds link here.
  get '/bookings/:booking_id/at/:step' do |booking_id:, step:|
    render_step UI::Booking::Page, booking_id, step
  end

  get '/bookings/:booking_id/diagram/at/:step' do |booking_id:, step:|
    render_step UI::Booking::DiagramPage, booking_id, step
  end

  # The cross-post explorer: a machine, and a state picked on it.
  get '/cross-post/explore/:machine' do |machine:|
    render_in_place UI::CrossPost::ExplorerPage.build(machine)
  end

  get '/cross-post/explore/:machine/:state' do |machine:, state:|
    render_in_place UI::CrossPost::ExplorerPage.build(machine, state)
  end

  private def render_step(page_class, *ids, step)
    step = Integer(step, 10, exception: false)
    render_in_place(step && page_class.at(*ids, step))
  end

  # A Datastar request (a step link in a history feed, a pick in the
  # explorer) gets the page patched in place, and its URL pushed onto the
  # browser's history; any other gets the whole page.
  private def render_in_place(page)
    halt 404, 'Not found' unless page
    return component(page) unless browser.sse?

    path = request.path
    browser.stream do |sse|
      sse.patch_elements page
      sse.execute_script "history.pushState({}, '', #{path.to_json})"
    end
  end
end

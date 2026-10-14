# frozen_string_literal: true

module UI
  # The Booking tab: the forms the booking's current configuration accepts.
  #
  # While the booking is at BookingStarted its three regions are active at
  # once, so they're shown side by side and can be filled in any order.
  class BookingPage < BookingFrame
    path '/bookings/:booking_id'

    def tab = :booking

    private

    def render_lead
      return unless @machine.in?(HolidayBooking::BookingStarted)

      p(class: 'booking__lead') do
        plain 'Fill these in any order: the three steps are parallel regions of '
        code { 'BookingStarted' }
        plain '. Once each one is final, the booking moves to checkout by itself.'
      end
    end

    def render_tab
      if @machine.in?(HolidayBooking::BookingStarted) then render_regions
      elsif @machine.in?(HolidayBooking::ItineraryReady) then render_checkout
      else render_outcome
      end
    end

    # ---- BookingStarted: three regions, side by side ----

    def render_regions
      div(class: 'regions') do
        region_card(:flight, 'Flight', HolidayBooking::FlightConfirmed) { render_flight }
        region_card(:hotel, 'Hotel', HolidayBooking::HotelConfirmed) { render_hotel }
        region_card(:extras, 'Extras', HolidayBooking::ExtrasChosen) { render_extras }
      end
    end

    def region_card(name, title, final, &)
      done = @machine.in?(name, final)
      section(class: ['region-card', ('region-card--done' if done)], aria: { label: title }) do
        header(class: 'region-card__header') do
          h2 { title }
          span(class: 'region-card__state') { position_name(name) }
        end
        yield
      end
    end

    def position_name(region)
      position = @machine.entered_by(region)
      position ? position.class.name.split('::').last : 'initial'
    end

    def render_flight
      flights = @trip.destination_info.flights

      if @machine.in?(:flight, HolidayBooking::FlightConfirmed)
        done_summary(flight_label(@trip.flight_info))
        return
      end

      ul(class: 'options') do
        flights.each do |flight|
          chosen = flight.code == @trip.flight
          li(class: ['option', ('option--chosen' if chosen)]) do
            div(class: 'option__body') do
              strong { "#{flight.airline} #{flight.code}" }
              span(class: 'option__note') { "#{flight.departs} → #{flight.arrives} · #{euros(flight.price)} pp" }
            end
            if chosen
              span(class: 'option__tag') { 'Chosen' }
            else
              action HolidayBooking::ChooseFlight, @trip.flight ? 'Switch' : 'Choose', key: flight.code, fields: { flight: flight.code }
            end
          end
        end
      end

      if @machine.in?(:flight, HolidayBooking::FlightChosen)
        action HolidayBooking::ConfirmFlight, 'Confirm flight', css: 'button button--primary'
      end
    end

    def render_hotel
      if @machine.in?(:hotel, HolidayBooking::HotelConfirmed)
        done_summary("#{@trip.hotel_info.name} · #{@trip.room_info.name} · #{@trip.board_info.name}")
        return
      end

      ul(class: 'options') do
        @trip.destination_info.hotels.each do |hotel|
          chosen = hotel.code == @trip.hotel
          li(class: ['option', ('option--chosen' if chosen)]) do
            div(class: 'option__body') do
              strong { hotel.name }
              span(class: 'option__note') { "#{'★' * hotel.stars} · #{euros(hotel.nightly)} a night" }
            end
            if chosen
              span(class: 'option__tag') { 'Chosen' }
            else
              action HolidayBooking::ChooseHotel, @trip.hotel ? 'Switch' : 'Choose', key: hotel.code, fields: { hotel: hotel.code }
            end
          end
        end
      end

      return unless @machine.in?(:hotel, HolidayBooking::HotelChosen)

      p(class: 'region-card__hint') do
        plain 'HotelChosen has two regions of its own. Switching hotel enters it again, which starts both over.'
      end
      div(class: 'subregions') do
        subregion(:room, 'Room', HolidayBooking::RoomChosen, Catalogue::ROOMS, HolidayBooking::ChooseRoom, :room, @trip.room_info)
        subregion(:board, 'Board', HolidayBooking::BoardChosen, Catalogue::BOARDS, HolidayBooking::ChooseBoard, :board, @trip.board_info)
      end
    end

    def subregion(name, title, final, options, command_class, field, picked)
      section(class: 'subregion', aria: { label: title }) do
        header(class: 'region-card__header') do
          h3 { title }
          span(class: 'region-card__state') { position_name(name) }
        end
        if @machine.in?(name, final)
          done_summary(picked.name)
        else
          ul(class: 'options options--compact') do
            options.each_value do |option|
              li(class: 'option') do
                div(class: 'option__body') do
                  strong { option.name }
                  span(class: 'option__note') { option.note }
                end
                action command_class, 'Choose', key: option.code, fields: { field => option.code }
              end
            end
          end
        end
      end
    end

    def render_extras
      if @machine.in?(:extras, HolidayBooking::ExtrasChosen)
        names = @trip.extras.map { |code| Catalogue::EXTRAS.fetch(code).name }
        done_summary(names.empty? ? 'No extras' : names.join(', '))
        return
      end

      p(class: 'region-card__hint') do
        plain 'Toggling an extra records data without moving the region. '
        plain 'Finishing is what makes it final.'
      end
      ul(class: 'options options--compact') do
        Catalogue::EXTRAS.each_value do |extra|
          added = @trip.extras.include?(extra.code)
          li(class: ['option', ('option--chosen' if added)]) do
            div(class: 'option__body') do
              strong { extra.name }
              span(class: 'option__note') { extra.note }
            end
            action HolidayBooking::ToggleExtra, added ? 'Remove' : 'Add', key: extra.code, fields: { extra: extra.code },
                                                            aria: { pressed: added.to_s }
          end
        end
      end
      action HolidayBooking::FinishExtras, 'Done with extras', css: 'button button--primary'
    end

    def done_summary(text)
      p(class: 'done-summary') do
        span(class: 'done-summary__tick', aria: { hidden: 'true' }) { '✓' }
        plain text
      end
    end

    # ---- ItineraryReady: pay before the hold runs out ----

    def render_checkout
      section(class: 'checkout', aria: { label: 'Checkout' }) do
        h2 { 'Checkout' }
        p do
          plain 'Every region is final, so the machine appended '
          code { 'ItineraryReady' }
          plain ' and started its timer. Pay before it runs out, or the hold expires.'
        end

        render_hold
        if @trip.declined
          p(class: 'notice notice--error', role: 'alert') { @trip.declined }
        end

        command HolidayBooking::Pay, class: 'pay-form' do |f|
          f.payload_fields(booking_id:)
          f.text_field :card_number, placeholder: '4242 4242 4242 4242', inputmode: 'numeric',
                                     autocomplete: 'off', aria: { label: 'Card number' }
          button(type: :submit, class: 'button button--primary') { "Pay #{euros(@trip.total)}" }
        end
        p(class: 'region-card__hint') { 'Any card number works. One ending in 0000 is declined.' }
      end
    end

    # A countdown while live. A past step shows when the hold was due to end.
    def render_hold
      unless @history.live?
        p(class: 'hold') do
          span { 'Held until ' }
          strong { @trip.hold_until.localtime.strftime('%H:%M:%S') }
        end
        return
      end

      seconds_left = [(@trip.hold_until - Time.now).ceil, 0].max
      p(class: 'hold', role: 'timer', aria: { live: 'off' }) do
        span { 'Held for ' }
        strong(
          data: {
            'signals:_left' => seconds_left.to_s,
            'on-interval__duration.1s' => '$_left = Math.max(0, $_left - 1)',
            'text' => "Math.floor($_left / 60) + ':' + String($_left % 60).padStart(2, '0')"
          }
        ) { format('%d:%02d', seconds_left / 60, seconds_left % 60) }
      end
    end

    # ---- Final checkpoints ----

    def render_outcome
      section(class: 'outcome', aria: { label: 'Booking outcome' }) do
        if @machine.in?(HolidayBooking::BookingConfirmed)
          h2 { 'Booked. Pack your telescope.' }
          p { "Your reference is #{@trip.reference}." }
        elsif @machine.in?(HolidayBooking::HoldExpired)
          h2 { 'The hold expired' }
          p { 'Checkout timed out before payment, so the itinerary was released.' }
        else
          h2 { 'Booking cancelled' }
          p { 'Nothing was charged.' }
        end
        a(href: '/', class: 'button button--primary') { 'Plan another trip' }
      end
    end

    def flight_label(flight) = "#{flight.airline} #{flight.code}, #{flight.departs} → #{flight.arrives}"
  end
end

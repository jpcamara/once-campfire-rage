module ApplicationCable
  class Channel < Rage::Cable::Channel
    include Campfire

    def stream_from(stream)
      (@streams ||= []) << stream
      super
    end

    private
      def runtime = Campfire.runtime
      def repo = runtime.repo

      def stop_all_streams
        @streams&.each { stop_stream_from(it) }
        @streams = nil
      end

      def user_room(room_id)
        room_id && repo.user_room(current_user.id, room_id.to_i)
      end
  end
end

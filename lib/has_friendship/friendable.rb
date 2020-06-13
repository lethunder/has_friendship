module HasFriendship
  module Friendable
    def friendable?
      false
    end

    def has_friendship
      class_eval do
        has_many :friendships, as: :friendable,
                 class_name: "HasFriendship::Friendship", dependent: :destroy

        has_many :blocked_friends,
                 -> { where friendships: {status: "blocked"} },
                 through: :friendships,
                 source: :friend

        has_many :friends,
                 -> { where friendships: { status: ["accepted", "blocked"] } },
                 through: :friendships,
                 source: :friend

        has_many :requested_friends,
                 -> { where friendships: {status: "requested"} },
                 through: :friendships,
                 source: :friend

        has_many :pending_friends,
                 -> { where friendships: {status: "pending"} },
                 through: :friendships,
                 source: :friend

        scope :unblocked, -> { where(friendships: { status: "accepted" })}

        def self.friendable?
          true
        end
      end

      include HasFriendship::Friendable::InstanceMethods
      include HasFriendship::Extender
    end

    module InstanceMethods
      CALLBACK_METHOD_NAMES = %i(
        on_friendship_created
        on_friendship_accepted
        on_friendship_blocked
        on_friendship_destroyed
      ).freeze

      CALLBACK_METHOD_NAMES.each do |method_name|
        define_method(method_name) do |*args|
          super(*args) if defined?(super)
        end
      end

      def friend_request(friend)
        unless self == friend || HasFriendship::Friendship.exist?(self, friend)
          transaction do
            HasFriendship::Friendship.create_relation(self, friend, status: "pending")
            HasFriendship::Friendship.create_relation(friend, self, status: "requested")
          end
        end
      end

      def suggested_friend_request(friend, suggester)
        unless self == friend || HasFriendship::Friendship.exist?(self, friend)
          transaction do
            HasFriendship::Friendship.create_relation(self, friend, status: "pending", suggester_id: suggester.id)
            HasFriendship::Friendship.create_relation(friend, self, status: "requested", suggester_id: suggester.id)
          end
        end
      end

      def accept_request(friend)
        on_relation_with(friend) do |one, other|
          friendship = HasFriendship::Friendship.find_unblocked_friendship(one, other)
          friendship.accept! if can_accept_request?(friendship)
        end
      end

      def add_friend(friend)
        friend.friend_request(self)
        accept_request(friend)
      end

      def mutual_friends_with(friend)
        friend.friends & friends
      end

      def decline_request(friend)
        on_relation_with(friend) do |one, other|
          HasFriendship::Friendship.find_unblocked_friendship(one, other).destroy
        end
      end

      alias_method :remove_friend, :decline_request

      def block_friend(friend)
        on_relation_with(friend) do |one, other|
          HasFriendship::Friendship.find_unblocked_friendship(one, other).block!
        end
      end

      def unblock_friend(friend)
        return unless has_blocked(friend)
        on_relation_with(friend) do |one, other|
          HasFriendship::Friendship.find_blocked_friendship(one, other).update_columns(blocker_id: nil, status: "accepted")
        end
      end

      def on_relation_with(friend)
        transaction do
          yield(self, friend)
          yield(friend, self)
        end
      end

      def friends_with?(friend)
        HasFriendship::Friendship.find_relation(self, friend, status: "accepted").any?
      end

      def has_blocked(friend)
        HasFriendship::Friendship.find_one_side(self, friend).blocker_id == self.id
      end
      private

      def can_accept_request?(friendship)
        return if friendship.pending? && self == friendship.friendable
        return if friendship.requested? && self == friendship.friend
        return if friendship.accepted?
        true
      end
    end
  end
end

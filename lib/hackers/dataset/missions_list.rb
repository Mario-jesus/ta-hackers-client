# frozen_string_literal: true

module Hackers
  ##
  # Missions list
  class MissionsList < Dataset
    include Enumerable

    Mission = Struct.new(
      :id,
      :giver_name,
      :name,
      :message_info,
      :goals,
      :x,
      :y,
      :country,
      :required_missions,
      :required_core_level,
      :reward_money,
      :reward_bitcoins,
      :message_completion,
      :message_news,
      :topology,
      :nodes,
      :additional_money,
      :additional_bitcoins,
      :group
    )

    def initialize(*)
      super

      @missions = []
    end

    def load
      @raw_data = nil
      @missions = []

      raw_data = @api.missions_list
      records = Serializer.parseData(raw_data)[0]
      missions = parse(records)
      @missions = missions
      @raw_data = raw_data
      records
    end

    def exist?(mission)
      @missions.any? { |m| m.id == mission }
    end

    def get(mission)
      @missions.detect { |m| m.id == mission }
    end

    def each(&block)
      @missions.each(&block)
    end

    private

    def parse(records)
      unless records.is_a?(Array)
        raise Serializer::ParserError, 'Missing missions section 0'
      end

      records.each_with_index.map do |record, index|
        unless record.is_a?(Array) && record[0].is_a?(String) && record[0].match?(/\A[+-]?\d+\z/)
          raise Serializer::ParserError, "Invalid mission ID at record #{index}"
        end

        Mission.new(
          record[0].to_i,
          record[1],
          Serializer.normalizeData(record[2]),
          record[3],
          Serializer.normalizeData(record[4]).split(','),
          record[5].to_i,
          record[6].to_i,
          record[7].to_i,
          Serializer.normalizeData(record[9]).split(','),
          record[12].to_i,
          record[13].to_i,
          record[14].to_i,
          Serializer.normalizeData(record[17]),
          Serializer.normalizeData(record[19]),
          Serializer.normalizeData(record[21]),
          Serializer.normalizeData(record[22]),
          record[24].to_i,
          record[25].to_i,
          record[28]
        )
      end
    end
  end
end

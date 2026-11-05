module Investigations
  class TopicCitationScope
    def self.disjoint_years?(claim:, reference:)
      years = claim.scan(/\b(?:em|in|ano|year|ciclo|cycle|per[ií]odo|period)\s+(?:civil\s+)?(?:de\s+|of\s+)?((?:19|20)\d{2})\b/i).flatten
      return false if years.empty?
      cited_years = reference.scan(/\b(?:19|20)\d{2}\b(?![.,]\d)(?!\s*(?:%|km|ha\b|hectare|pessoa|people|voto|vote|unidade|unit|tonelada))/i)
      cited_years.any? && (years & cited_years).empty?
    end
  end
end

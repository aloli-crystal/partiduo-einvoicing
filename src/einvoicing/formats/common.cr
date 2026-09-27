# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"
require "big"

module Einvoicing
  # Formats de la facture électronique (ADR-004 D3) : production (UBL 2.1,
  # variantes CII, CDAR, e-reporting) et lecture (UBL, CII, Factur-X).
  # Interne ; les écrans les obtiennent par `Einvoicing::Api`.
  module Formats
    # Identifiants de spécification (BT-24).
    EN16931         = "urn:cen.eu:en16931:2017"
    EXTENDED_CTC_FR = "urn:cen.eu:en16931:2017#conformant#urn.cpro.gouv.fr:1p0:extended-ctc-fr"
    PEPPOL_BIS3     = "urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0"
    PEPPOL_PROFILE  = "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

    # Profils produits à la demande, par code d'export.
    PROFILES = {"en16931" => EN16931, "extended-ctc-fr" => EXTENDED_CTC_FR}

    # Schémas d'identifiants (ISO 6523 ICD) : SIREN, SIRET, adresse de
    # l'annuaire français, numéro d'entreprise belge.
    SCHEME_SIREN     = "0002"
    SCHEME_SIRET     = "0009"
    SCHEME_FR_ADDR   = "0225"
    SCHEME_BE_NUMBER = "0208"

    # Codes de type d'un avoir (UNTDID 1001).
    CREDIT_TYPE_CODES = %w[381 261 262 296 308 396 420 458 532]

    # Montant à deux décimales, arrondi au plus proche (moitié vers
    # l'extérieur), sans exposant.
    def self.amount(value : BigDecimal, digits : Int32 = 2) : String
      rounded = value.round(digits, mode: :ties_away)
      negative = rounded < 0
      integer, _, fraction = plain(rounded.abs).partition('.')
      fraction = fraction.ljust(digits, '0')[0, digits]
      digits.zero? ? "#{negative ? "-" : ""}#{integer}" : "#{negative ? "-" : ""}#{integer}.#{fraction}"
    end

    # Écriture décimale sans exposant (`BigDecimal#to_s` écrit `1.0e-5`).
    def self.plain(value : BigDecimal) : String
      digits = value.value.abs.to_s
      scale = value.scale.to_i32
      if scale > 0
        digits = digits.rjust(scale + 1, '0')
        integer = digits[0, digits.size - scale]
        fraction = digits[digits.size - scale, scale].rstrip('0')
        digits = fraction.empty? ? integer : "#{integer}.#{fraction}"
      end
      value.value < 0 ? "-#{digits}" : digits
    end

    # Décimal lu dans un document ; `nil` si illisible.
    def self.decimal(text : String?) : BigDecimal?
      value = text.try(&.strip)
      return if value.nil? || value.empty?
      BigDecimal.new(value)
    rescue ArgumentError | InvalidBigDecimalException
      nil
    end

    # Date `AAAAMMJJ` (format 102) ou `AAAA-MM-JJ`, à minuit UTC.
    def self.date(text : String?) : Time?
      value = text.try(&.strip) || ""
      if value.matches?(/\A\d{8}\z/)
        Time.parse_utc(value, "%Y%m%d")
      elsif value.matches?(/\A\d{4}-\d{2}-\d{2}/)
        Time.parse_utc(value[0, 10], "%Y-%m-%d")
      end
    rescue Time::Format::Error
      nil
    end

    # SIREN tiré d'un identifiant : SIREN, SIRET, adresse de l'annuaire
    # (`SIREN_…`), numéro de TVA français (`FRxx` + SIREN) ; vide sinon.
    def self.siren_from(value : String, scheme : String = "") : String
      digits = value.gsub(/[\s.]/, "")
      case scheme
      when SCHEME_SIREN, SCHEME_SIRET, SCHEME_FR_ADDR
        head = digits.split('_').first
        return head[0, 9] if head.matches?(/\A\d{9}(\d{5})?\z/)
      end
      if match = digits.upcase.match(/\AFR[0-9A-Z]{2}(\d{9})\z/)
        return match[1]
      end
      ""
    end
  end
end

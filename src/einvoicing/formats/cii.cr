# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Formats
    # Variantes CII d'une facture émise (ADR-004 D3). La source est le XML
    # CII que le module Facturation embarque dans le PDF/A-3 Factur-X
    # (`Partiduo::Api::Invoicing.facturx_xml`, profil EN 16931) : une seule
    # production des montants et des mentions, identique au PDF. L'extension
    # n'en change que l'en-tête :
    #
    # * profil EN 16931 ou EXTENDED-CTC-FR (identifiant de spécification,
    #   BT-24) — les éléments EN 16931 sont un sous-ensemble admis
    #   d'EXTENDED-CTC-FR ;
    # * note `BAR` = `B2C` pour une vente à un particulier transmise pour
    #   e-reporting (ADR-004 D8).
    #
    # Les espaces de noms CII sont les mêmes de D16B à D22B : le XML produit
    # est lu comme du CII D22B (DECISIONS D-EINV-006).
    module Cii
      GUIDELINE = %r{(<ram:GuidelineSpecifiedDocumentContextParameter>\s*<ram:ID>)([^<]*)(</ram:ID>)}
      NOTE_AT   = %r{(</ram:IssueDateTime>)}

      class Error < Exception
      end

      def self.variant(xml : String, profile : String = EN16931, b2c : Bool = false) : String
        raise Error.new("XML CII sans identifiant de spécification") unless xml.matches?(GUIDELINE)
        result = xml.sub(GUIDELINE) { "#{$~[1]}#{profile}#{$~[3]}" }
        if b2c
          raise Error.new("XML CII sans date d'émission") unless result.matches?(NOTE_AT)
          note = "<ram:IncludedNote><ram:Content>B2C</ram:Content><ram:SubjectCode>BAR</ram:SubjectCode></ram:IncludedNote>"
          result = result.sub(NOTE_AT) { "#{$~[1]}#{note}" }
        end
        result
      end
    end
  end
end

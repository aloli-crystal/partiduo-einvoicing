# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  module Api
    # Routes d'une facture émise (ADR-004 D8, D9). Libellé :
    # `einvoicing.routes.<code>`.
    ROUTES = %w[platform b2c international off_platform]

    # Statuts d'une facture émise. Libellé : `einvoicing.transmission_statuses.<code>`.
    TRANSMISSION_STATUSES = %w[pending submitted deposited rejected refused approved paid ereporting off_platform]

    # Statuts d'une facture reçue. Libellé : `einvoicing.reception_statuses.<code>`.
    RECEPTION_STATUSES = %w[received accepted refused posted]

    # Fichiers d'une facture émise produits à la demande (ADR-004 D3) :
    # PDF/A-3 Factur-X du module Facturation, CII (EN 16931 et
    # EXTENDED-CTC-FR), UBL 2.1 EN 16931, UBL PEPPOL BIS 3.
    EXPORT_FORMATS = %w[facturx cii extended-ctc-fr ubl peppol]

    # Motifs de refus proposés (codes des spécifications externes).
    # Libellé : `einvoicing.refusal_reasons.<code>`.
    REFUSAL_REASONS = %w[DOUBLON DEST_ERR MONTANTTOTAL_ERR TX_TVA_ERR CMD_ERR LIVR_INCOMP NON_CONFORME AUTRE]

    # Codes AFNOR du cycle de vie (ADR-004 D4). Libellé :
    # `einvoicing.codes.<code>`.
    CODES = %w[200 201 202 203 204 205 206 207 208 209 210 211 212 213 214 220]

    # Paramètre d'un adaptateur, tel que l'écran le montre : la valeur d'un
    # secret n'est jamais rendue, seulement `stored` (déjà enregistré).
    record FieldView,
      name : String,
      secret : Bool,
      required : Bool,
      kind : String,
      choices : Array(String),
      value : String,
      stored : Bool,
      label_key : String,
      choice_prefix : String = "einvoicing.modes" do
      # Clé du libellé d'un choix.
      def choice_key(choice : String) : String
        "#{choice_prefix}.#{choice}"
      end
    end

    # Adaptateur disponible ; `available` : admis pour le régime du dossier.
    record AdapterView, code : String, label_key : String, available : Bool, fields : Array(FieldView)

    # Raccordement du dossier. `mode` : `sandbox` ou `production` (affiché
    # en permanence, ADR-004 D8).
    record ConnectionView,
      adapter : String,
      label_key : String,
      active : Bool,
      mode : String,
      fields : Array(FieldView),
      last_sync_at : Time?,
      last_error : String,
      updated_at : Time

    # Paramètres saisis ; un secret laissé vide garde la valeur enregistrée.
    record ConnectionInput, adapter : String, values : Hash(String, String) = {} of String => String

    record TransmissionView,
      id : Int64,
      invoice_id : Int64,
      kind : String,
      number : String,
      type_code : String,
      customer_card_id : Int64?,
      customer_name : String,
      customer_country : String,
      issue_date : Time?,
      currency_code : String,
      total_net : BigDecimal,
      total_vat : BigDecimal,
      total_gross : BigDecimal,
      channel : String,
      b2c : Bool,
      route : String,
      platform_required : Bool,
      status : String,
      last_code : String,
      adapter : String,
      syntax : String,
      profile : String,
      platform_ref : String?,
      tracking_id : String,
      submitted_at : Time?,
      attempts : Int32,
      error : String,
      created_at : Time do
      def status_key : String
        "einvoicing.transmission_statuses.#{status}"
      end

      def route_key : String
        "einvoicing.routes.#{route}"
      end

      # À transmettre (ou à retransmettre après un échec réseau ou un rejet).
      def transmittable? : Bool
        route.in?("platform", "b2c") && status.in?("pending", "rejected")
      end
    end

    record TransmissionQuery,
      status : String? = nil,
      search : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0

    # Ligne d'une facture reçue.
    record LineView,
      description : String,
      quantity : BigDecimal,
      unit_code : String,
      unit_price : BigDecimal?,
      net : BigDecimal,
      vat_category : String,
      vat_percent : BigDecimal?

    # Ligne du récapitulatif de TVA d'une facture reçue.
    record VatLineView, category : String, percent : BigDecimal, base : BigDecimal, amount : BigDecimal

    record ReceptionView,
      id : Int64,
      platform_ref : String,
      adapter : String,
      receipt_id : Int64?,
      syntax : String,
      profile : String,
      type_code : String,
      number : String,
      issue_date : Time?,
      due_date : Time?,
      currency_code : String,
      supplier_name : String,
      supplier_siren : String,
      supplier_vat : String,
      supplier_country : String,
      supplier_card_id : Int64?,
      buyer_siren : String,
      total_net : BigDecimal?,
      total_vat : BigDecimal?,
      total_gross : BigDecimal?,
      payable : BigDecimal?,
      lines : Array(LineView),
      vat_lines : Array(VatLineView),
      notes : Array(String),
      read_errors : Array(String),
      status : String,
      entry_id : Int64?,
      received_invoice_id : Int64?,
      decided_at : Time?,
      received_at : Time do
      def status_key : String
        "einvoicing.reception_statuses.#{status}"
      end

      def credit_note? : Bool
        Formats::CREDIT_TYPE_CODES.includes?(type_code)
      end

      # Montant signé pour la comptabilité et les doublons (négatif pour un
      # avoir, comme `ReceivedInvoiceInput`).
      def signed_gross : BigDecimal?
        total_gross.try { |value| credit_note? ? -value : value }
      end

      def undecided? : Bool
        status.in?("received", "accepted")
      end
    end

    record ReceptionQuery,
      status : String? = "received",
      search : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0

    # Événement du cycle de vie (ADR-004 D4).
    record EventView,
      id : Int64,
      code : String,
      occurred_at : Time,
      issuer : String,
      reason_code : String,
      reason : String,
      amount : BigDecimal?,
      state : String,
      sent_at : Time?,
      error : String do
      def label_key : String
        "einvoicing.codes.#{code}"
      end

      def issuer_key : String
        "einvoicing.issuers.#{issuer}"
      end

      def state_key : String
        "einvoicing.event_states.#{state}"
      end
    end

    # Refus d'une facture reçue (statut 210) : motif codé et texte libre.
    record RefuseInput, reason_code : String, reason : String = ""

    # Doublons possibles d'une facture reçue (ADR-004 D9) : autres factures
    # reçues par la plateforme (même fournisseur, même numéro), factures
    # d'achat déjà enregistrées en Comptabilité, y compris celles reçues
    # hors plateforme (`received_invoice_duplicates` du cœur).
    record DuplicatesView,
      receptions : Array(ReceptionView),
      received_invoices : Array(Partiduo::Api::Accounting::ReceivedInvoiceView) do
      def found? : Bool
        !receptions.empty? || !received_invoices.empty?
      end
    end

    # Résultat d'une synchronisation avec la plateforme.
    record SyncView,
      transmitted : Int32,
      received : Int32,
      statuses : Int32,
      sent_statuses : Int32,
      reports : Int32,
      errors : Array(String)

    # Ligne de l'annuaire ; `card_code` : fiche du socle de même SIREN.
    record DirectoryEntryView,
      address : String,
      scheme : String,
      name : String,
      siren : String,
      siret : String,
      routing_id : String,
      platform : String,
      status : String,
      card_code : String?

    # Fichier produit ou reçu.
    record FileView, filename : String, content_type : String, content : Bytes

    # Nombre de factures reçues à traiter, factures émises en attente ou
    # rejetées (menus, tableau de bord).
    record CountsView, incoming_to_process : Int64, outgoing_pending : Int64, outgoing_rejected : Int64
  end
end

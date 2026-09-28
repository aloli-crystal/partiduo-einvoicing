# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Message d'erreur conservé en base ou rendu par le contrat (dernière
  # erreur du raccordement, erreur d'une facture émise, d'un statut, d'un lot
  # d'e-reporting) : une clé i18n et ses paramètres, traduits à la lecture
  # dans la langue de l'utilisateur (DECISIONS D-EINV-024). Le texte brut
  # renvoyé par une plateforme n'est jamais traduit : il reste un paramètre
  # (`detail`). Un texte enregistré sans clé (antérieur, ou motif de rejet
  # de la plateforme) est rendu tel quel.
  module ErrorText
    PREFIX = "i18n:"

    # Clé d'un texte brut, rendu tel quel.
    RAW = "einvoicing.errors.transport.raw"

    def self.encode(key : String, params : Hash(String, String) = {} of String => String) : String
      "#{PREFIX}#{({"key" => key, "params" => params}).to_json}"
    end

    # Clé et paramètres d'un texte enregistré.
    def self.decode(text : String) : {String, Hash(String, String)}
      if text.starts_with?(PREFIX)
        json = JSON.parse(text[PREFIX.size..]) rescue nil
        if json && (key = json["key"]?.try(&.as_s?))
          params = {} of String => String
          json["params"]?.try(&.as_h?).try(&.each { |name, value| params[name] = value.as_s? || value.to_s })
          return {key, params}
        end
      end
      {RAW, {"detail" => text}}
    end

    # Texte traduit dans la langue courante ; un paramètre lui-même encodé
    # (erreur d'une facture dans la ligne de synchronisation) est traduit
    # aussi.
    def self.translate(text : String) : String
      return "" if text.empty?
      key, params = decode(text)
      translate(key, params)
    end

    def self.translate(key : String, params : Hash(String, String)) : String
      return params["detail"]? || "" if key == RAW
      values = params.transform_values { |value| value.starts_with?(PREFIX) ? translate(value) : value }
      I18n.t(key, values)
    end
  end

  # Échec d'un échange avec la plateforme agréée (réseau, authentification,
  # réponse inattendue). La synchronisation le consigne et reprendra au même
  # curseur ; rien n'est perdu. `message` (journaux) reste en français ;
  # l'écran lit `key` et `params` (`text`, `localized`), où le texte brut de
  # la plateforme n'est qu'un paramètre `detail`.
  class ConnectorError < Exception
    getter status : Int32?
    getter key : String
    getter params : Hash(String, String)

    def initialize(message : String, @status : Int32? = nil, key : String? = nil,
                   params : Hash(String, String)? = nil)
      super(message)
      @key = key || ErrorText::RAW
      @params = params || {"detail" => message}
    end

    # Texte à enregistrer (`ErrorText.encode`).
    def text : String
      ErrorText.encode(key, params)
    end

    # Texte traduit dans la langue courante.
    def localized : String
      ErrorText.translate(key, params)
    end
  end

  # Opération que la plateforme ne propose pas (statuts du point d'accès
  # Peppol Belgique, e-reporting hors de France…).
  class Unsupported < ConnectorError
  end

  # Connecteur vers une plateforme agréée (ADR-004 D2). Un dossier n'a qu'un
  # adaptateur actif à la fois (`Einvoicing::Connections`) ; le code métier ne
  # dépend d'aucune plateforme particulière (ADR-004 D6).
  #
  # *Synchronisation par curseur, jamais par date* : la réception et les
  # statuts se lisent à partir du dernier élément reçu (curseur opaque propre
  # à l'adaptateur, conservé en base), page après page tant que la
  # plateforme en annonce d'autres (`Page#has_more`).
  abstract class Connector
    # Curseur opaque : l'extension le conserve tel quel entre deux
    # synchronisations et le rend à l'adaptateur.
    record Cursor, value : String

    # Page d'une lecture : éléments, curseur à conserver (celui du dernier
    # élément lu), et s'il reste d'autres pages.
    record Page(T), items : Array(T), cursor : Cursor?, has_more : Bool

    # Partie d'une facture vue par la plateforme : nom, SIREN (schéma
    # `0002`), SIRET, numéro de TVA, pays, adresse électronique de
    # l'annuaire et son schéma (`0225` en France, `0208` en Belgique).
    record Party,
      name : String,
      siren : String = "",
      siret : String = "",
      vat_number : String = "",
      country_code : String = "",
      electronic_address : String = "",
      scheme : String = ""

    # Facture à transmettre : le fichier (PDF/A-3 Factur-X produit par le
    # module Facturation, ou XML CII / UBL), sa syntaxe (`Factur-X`, `CII`,
    # `UBL`) et son profil (`EN16931`, `EXTENDED-CTC-FR`, `BASIC-WL`), la
    # règle de traitement (`B2B`, `B2C`, `B2BInt`), le destinataire.
    # `tracking_id` : identifiant propre à Partiduo, repris par la plateforme.
    record OutgoingInvoice,
      invoice_id : Int64,
      number : String,
      type_code : String,
      syntax : String,
      profile : String,
      filename : String,
      content_type : String,
      content : Bytes,
      processing_rule : String,
      seller : Party,
      buyer : Party,
      tracking_id : String,
      sha256 : String

    # Réponse au dépôt : identifiant donné par la plateforme, état immédiat
    # (`pending` en attente de contrôle, `ok` déposée, `error` rejetée) et
    # motif d'un rejet.
    record Submission,
      platform_ref : String,
      status : String = "pending",
      reason_code : String = "",
      reason : String = ""

    # Facture reçue : identifiant chez la plateforme, fichier tel que reçu
    # (UBL, CII ou PDF Factur-X), syntaxe annoncée, expéditeur, date.
    record IncomingInvoice,
      platform_ref : String,
      filename : String,
      content : Bytes,
      syntax : String? = nil,
      sender : String = "",
      received_at : Time = Time.utc

    # Événement du cycle de vie (ADR-004 D4) : code AFNOR (`200` Déposée,
    # `210` Refusée, `212` Encaissée, `213` Rejetée…), date, motif, émetteur
    # (`platform`, `buyer`, `seller`). `invoice_ref` : identifiant de la
    # facture chez la plateforme (ou son `tracking_id`) ; `invoice_number`,
    # `invoice_date` et les parties : pour un statut émis (CDAR).
    # `direction` : `outgoing` (facture émise par le dossier) ou `incoming`.
    record LifecycleEvent,
      code : String,
      occurred_at : Time,
      direction : String = "outgoing",
      invoice_ref : String = "",
      invoice_number : String = "",
      invoice_date : Time? = nil,
      type_code : String = "380",
      issuer : String = "platform",
      reason_code : String = "",
      reason : String = "",
      amount : BigDecimal? = nil,
      currency_code : String = "EUR",
      platform_ref : String? = nil,
      seller : Party? = nil,
      buyer : Party? = nil

    # Ligne d'e-reporting (ADR-004 D8) : transaction B2C ou internationale,
    # ou encaissement.
    record EReportingEntry,
      invoice_number : String,
      date : Time,
      type_code : String,
      currency_code : String,
      net : BigDecimal,
      vat : BigDecimal,
      gross : BigDecimal,
      counterpart_country : String,
      counterpart_name : String = "",
      counterpart_vat : String = "",
      category : String = "services"

    # Lot d'e-reporting : `kind` (`b2c_transactions`, `b2c_payments`,
    # `international_sales`, `international_purchases`), période couverte,
    # déclarant (SIREN), lignes.
    record EReportingBatch,
      kind : String,
      period_start : Time,
      period_end : Time,
      declarant : Party,
      entries : Array(EReportingEntry),
      tracking_id : String

    # Ligne de l'annuaire : adresse de facturation électronique (`SIREN`,
    # `SIREN_SIRET`, `SIREN_SUFFIXE`, `SIREN_SIRET_CODEROUTAGE`), schéma,
    # nom, plateforme de réception, état de la ligne.
    record DirectoryEntry,
      address : String,
      scheme : String,
      name : String,
      siren : String = "",
      siret : String = "",
      routing_id : String = "",
      platform : String = "",
      status : String = ""

    # Dépose une facture.
    abstract def submit(invoice : OutgoingInvoice) : Submission

    # Factures reçues après `after` (`nil` : depuis le début).
    abstract def fetch_incoming(after : Cursor?) : Page(IncomingInvoice)

    # Émet un statut du cycle de vie (Refusée 210, Encaissée 212…).
    abstract def send_status(event : LifecycleEvent) : Nil

    # Statuts reçus après `after`, sur les factures émises ou reçues.
    abstract def fetch_statuses(after : Cursor?) : Page(LifecycleEvent)

    # Transmet un lot d'e-reporting.
    abstract def send_ereporting(batch : EReportingBatch) : Nil

    # Confirme à la plateforme la bonne réception des factures (point
    # d'accès qui retient les factures jusqu'à confirmation) ; sans effet
    # par défaut.
    def acknowledge(invoices : Array(IncomingInvoice)) : Nil
    end

    # Recherche dans l'annuaire : SIREN, SIRET ou adresse électronique.
    def lookup(query : String) : Array(DirectoryEntry)
      raise Unsupported.new("annuaire non proposé par cette plateforme", key: "einvoicing.errors.transport.no_directory")
    end

    # Vérifie le raccordement (authentification comprise).
    abstract def check : Nil

    # `sandbox` ou `production`, déduit des identifiants (affiché en
    # permanence dans l'écran de raccordement, ADR-004 D8).
    abstract def mode : String

    # Syntaxe préférée pour transmettre une facture : `Factur-X` (le PDF/A-3
    # du module Facturation), `CII` ou `UBL`.
    def preferred_syntax : String
      "Factur-X"
    end
  end
end

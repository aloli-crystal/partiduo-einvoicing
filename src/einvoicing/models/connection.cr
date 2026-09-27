# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Raccordement du dossier à une plateforme agréée (ADR-004 D2) : un
  # adaptateur (`AFNOR`, `NOALYSS_PEPPOL`, ou celui d'une extension
  # `partiduo-<pa>`), ses paramètres, ses secrets et ses jetons *chiffrés*
  # (`Einvoicing::Secrets`), les curseurs de synchronisation. Une seule ligne
  # active à la fois (index unique partiel posé par la migration).
  # Interne : on le lit et on l'écrit par `Einvoicing::Api`.
  class Connection < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :adapter, :string, max_size: 32, unique: true
    field :active, :bool, default: false
    # Paramètres non secrets (adresses, identifiants publics), en JSON.
    field :settings, :json
    # Secrets (`client_secret`, jeton d'accès permanent…), JSON chiffré.
    field :secrets, :text, blank: true, default: ""
    # Jeton d'accès en cours et jeton de rafraîchissement, chiffrés.
    field :access_token, :text, blank: true, default: ""
    field :access_token_expires_at, :date_time, blank: true, null: true
    field :refresh_token, :text, blank: true, default: ""
    # Curseurs opaques de l'adaptateur (réception, statuts), ADR-004 D2.
    field :incoming_cursor, :text, blank: true, null: true
    field :status_cursor, :text, blank: true, null: true
    field :last_sync_at, :date_time, blank: true, null: true
    field :last_error, :text, blank: true, default: ""
    field :updated_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end

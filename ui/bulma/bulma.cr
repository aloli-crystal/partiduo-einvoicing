# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension EINV (ADR-005 D4) : factures émises (statuts,
# transmission, fichiers), factures reçues (accepter, refuser,
# pré-comptabiliser), raccordement de la plateforme agréée, annuaire. Montée
# par `partiduo-ui-bulma` sous `/ext/EINV/` (ADR-003 D3). La distribution la
# requiert après l'interface et celle de DOCUMENT :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-einvoicing"
# require "partiduo-document/ui/bulma"
# require "partiduo-einvoicing/ui/bulma"
# ```
#
# puis ajoute `Einvoicing::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Einvoicing::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle d'accès
# est fait par l'interface, avant le handler, à partir du manifeste.
require "../../src/partiduo-einvoicing"

require "./presenters"
require "./handlers/**"

module Einvoicing
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/einvoicing/`), fichiers statiques (`assets/einvoicing/`) et
    # libellés d'écran (`locales/`, clés `einvoicing_ui.*`).
    class App < Marten::App
      label "einvoicing_ui"
    end

    INSTALLED_APPS = [Einvoicing::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/EINV/`, nommées `einv:<nom>` : ce sont les
    # routes que citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Einvoicing::Ui::IndexHandler, name: "index"
      path "/outgoing", Einvoicing::Ui::OutgoingHandler, name: "outgoing"
      path "/outgoing/<id:int>", Einvoicing::Ui::OutgoingShowHandler, name: "outgoing_show"
      path "/outgoing/<id:int>/transmit", Einvoicing::Ui::TransmitHandler, name: "transmit"
      path "/outgoing/<id:int>/file/<format:str>", Einvoicing::Ui::OutgoingFileHandler, name: "outgoing_file"
      path "/incoming", Einvoicing::Ui::IncomingHandler, name: "incoming"
      path "/incoming/import", Einvoicing::Ui::ImportHandler, name: "import"
      path "/incoming/<id:int>", Einvoicing::Ui::IncomingShowHandler, name: "incoming_show"
      path "/incoming/<id:int>/accept", Einvoicing::Ui::AcceptHandler, name: "accept"
      path "/incoming/<id:int>/refuse", Einvoicing::Ui::RefuseHandler, name: "refuse"
      path "/incoming/<id:int>/post", Einvoicing::Ui::PostHandler, name: "post"
      path "/incoming/<id:int>/file/<variant:str>", Einvoicing::Ui::IncomingFileHandler, name: "incoming_file"
      path "/sync", Einvoicing::Ui::SyncHandler, name: "sync"
      path "/settings", Einvoicing::Ui::SettingsHandler, name: "settings"
      path "/settings/check", Einvoicing::Ui::CheckHandler, name: "settings_check"
      path "/settings/disconnect", Einvoicing::Ui::DisconnectHandler, name: "settings_disconnect"
      path "/directory", Einvoicing::Ui::DirectoryHandler, name: "directory"
    end

    # Permission de chaque route ; les autres : `einvoicing.invoice.read`.
    # La synchronisation admet l'envoi ou la réception : le contrat le
    # vérifie.
    ROUTE_PERMISSIONS = {
      "transmit"            => Einvoicing::Api::SEND,
      "import"              => Einvoicing::Api::RECEIVE,
      "accept"              => Einvoicing::Api::RECEIVE,
      "refuse"              => Einvoicing::Api::RECEIVE,
      "post"                => Einvoicing::Api::RECEIVE,
      "settings"            => Einvoicing::Api::CONFIGURE,
      "settings_check"      => Einvoicing::Api::CONFIGURE,
      "settings_disconnect" => Einvoicing::Api::CONFIGURE,
    }
  end
end

PartiduoUi::Extensions.mount Einvoicing::CODE, Einvoicing::Ui::ROUTES, permission: Einvoicing::Api::READ,
  permissions: Einvoicing::Ui::ROUTE_PERMISSIONS

# Compteurs du menu : factures reçues à traiter ; factures émises à
# transmettre ou rejetées.
PartiduoUi::Extensions.counter("EINV_IN", route: "einv:incoming", todo: "einvoicing_ui.todo.incoming") do |actor|
  Einvoicing::Api.pending_count(actor)
end
PartiduoUi::Extensions.counter("EINV_OUT", route: "einv:outgoing", todo: "einvoicing_ui.todo.outgoing", tone: "warning") do |actor|
  Einvoicing::Api.outgoing_attention_count(actor)
end

# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension EINV (ADR-003 D2, ADR-004 D1), successeur de
# `peppol-connect` de NOALYSS.
#
# * Dépendance : `DOCUMENT` seulement (`depends_on`), car les factures reçues
#   entrent dans la boîte « Justificatifs à traiter » par son API publique.
#   La réception fonctionne sur le socle seul (ADR-003, sort des extensions
#   amont) ; l'émission exige la Facturation, la pré-comptabilisation la
#   Comptabilité : ces deux modules sont vérifiés à l'appel
#   (`Partiduo::Modules.active?`), comme DOCUMENT le fait (D-DOC-002,
#   DECISIONS D-EINV-002).
# * Permissions : `einvoicing.invoice.read` (écrans, fichiers, annuaire),
#   `einvoicing.invoice.send` (transmettre, synchroniser),
#   `einvoicing.invoice.receive` (accepter, refuser, pré-comptabiliser),
#   `einvoicing.settings.manage` (adaptateur de plateforme agréée).
# * Menus : factures émises sous « Facturation », factures reçues sous
#   « Saisie » (à côté des justificatifs), annuaire sous « Référentiel »,
#   raccordement sous « Paramètres ».
# * Abonnements : `invoice.issued` et `credit_note.issued` (facture à
#   transmettre, e-reporting), `payment.matched` et `payment.recorded`
#   (statut « Encaissée » 212, ADR-004 D4).
Partiduo::Modules.register do
  code "EINV"
  name "einvoicing.module.name"
  version "0.1.0"
  requires_core "~> 0.1"
  depends_on "DOCUMENT"

  permission "einvoicing.invoice.read"
  permission "einvoicing.invoice.send"
  permission "einvoicing.invoice.receive"
  permission "einvoicing.settings.manage"

  menu "EINV_OUT", parent: "BILLING", order: 80, route: "einv:outgoing", permission: "einvoicing.invoice.read",
    label: "einvoicing.menu.outgoing"
  menu "EINV_IN", parent: "ENTRY", order: 6, route: "einv:incoming", permission: "einvoicing.invoice.read",
    label: "einvoicing.menu.incoming"
  menu "EINV_DIRECTORY", parent: "REFERENCE", order: 90, route: "einv:directory", permission: "einvoicing.invoice.read",
    label: "einvoicing.menu.directory"
  menu "EINV_SETTINGS", parent: "SETTINGS", order: 90, route: "einv:settings", permission: "einvoicing.settings.manage",
    label: "einvoicing.menu.settings"

  ui "bulma", path: "ui/bulma"

  on("invoice.issued") { |event| Einvoicing::Outgoing.issued(event) }
  on("credit_note.issued") { |event| Einvoicing::Outgoing.issued(event) }
  on("payment.matched") { |event| Einvoicing::Lifecycle.payment_matched(event) }
  on("payment.recorded") { |event| Einvoicing::Lifecycle.payment_recorded(event) }
end

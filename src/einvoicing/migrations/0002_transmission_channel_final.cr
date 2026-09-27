# SPDX-License-Identifier: AGPL-3.0-or-later

# Canal d'une facture émise relu avant chaque transmission (D-INV-016 : le
# canal reste modifiable jusqu'à l'envoi ; DECISIONS D-EINV-021). Une fois la
# facture envoyée (canal figé par la Facturation) ou déposée à la
# plateforme, `channel_final` évite de relire le document à chaque
# synchronisation.
class Migration::Einvoicing::V0002 < Marten::Migration
  depends_on :einvoicing, "0001_create_einvoicing"

  def plan
    add_column :einvoicing_transmission, :channel_final, :bool, default: false
  end
end

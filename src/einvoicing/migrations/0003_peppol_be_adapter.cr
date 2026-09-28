# SPDX-License-Identifier: AGPL-3.0-or-later

# L'adaptateur du point d'accès belge s'appelle désormais `PEPPOL_BE`
# (DECISIONS D-EINV-028). Les raccordements, factures émises et factures
# reçues enregistrés sous l'ancien code (`<ÉDITEUR>_PEPPOL`) le reprennent ;
# le nom de l'en-tête d'authentification, jusqu'ici fixé dans le code
# (`<Éditeur>-Authz`), devient le paramètre `auth_header` du raccordement,
# déduit de l'ancien code. Sans retour : l'ancien code n'est plus compilé.
class Migration::Einvoicing::V0003 < Marten::Migration
  depends_on :einvoicing, "0002_transmission_channel_final"

  # Ancien code de l'adaptateur belge : un seul mot suivi de `_PEPPOL`.
  LEGACY = "adapter ~ '^[A-Z]+_PEPPOL$'"

  CONNECTIONS = <<-SQL
    UPDATE einvoicing_connection
       SET settings = (coalesce(settings::jsonb, '{}'::jsonb)
                       || jsonb_build_object('auth_header', initcap(split_part(adapter, '_', 1)) || '-Authz')),
           adapter = 'PEPPOL_BE'
     WHERE #{LEGACY}
    SQL
  TRANSMISSIONS = "UPDATE einvoicing_transmission SET adapter = 'PEPPOL_BE' WHERE #{LEGACY}"
  RECEPTIONS    = "UPDATE einvoicing_reception SET adapter = 'PEPPOL_BE' WHERE #{LEGACY}"

  def plan
    execute CONNECTIONS
    execute TRANSMISSIONS
    execute RECEPTIONS
  end
end

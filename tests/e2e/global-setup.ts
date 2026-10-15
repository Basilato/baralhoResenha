import { execSync } from 'node:child_process'

// Fecha salas que sobraram de execuções anteriores (o limite é 5 abertas por
// pessoa). Só para o banco local de desenvolvimento.
export default function globalSetup() {
  execSync(
    'docker exec supabase_db_baralho-da-resenha psql -U postgres -qc ' +
      `"update app_private.games set status = 'cancelled', finished_at = now() where status in ('lobby', 'playing'); update app_private.game_invites set active = false; delete from app_private.join_failures;"`,
    { stdio: 'ignore' },
  )
}

-- Tareas programadas de la pichanga. pg_cron solo existe en Supabase: las pruebas locales (PGlite) omiten
-- este archivo y llaman directo a las funciones interno.*.
-- cron.schedule con un nombre existente reemplaza la tarea, así que este archivo se puede volver a aplicar.

create extension if not exists pg_cron with schema pg_catalog;

-- Crear el partido de cada semana cuando se abre su inscripción.
select cron.schedule('pichanguita-generar-partidos', '*/10 * * * *', $$select interno.generar_partidos()$$);

-- Ofertas de la banca vencidas: vuelven al final y el cupo pasa al siguiente.
select cron.schedule('pichanguita-vencer-ofertas', '* * * * *', $$select interno.vencer_ofertas()$$);

-- Partidos que nadie cerró: se cierran 24 horas después del inicio.
select cron.schedule('pichanguita-cerrar-olvidados', '*/15 * * * *', $$select interno.cerrar_partidos_olvidados()$$);

-- Limpieza diaria (04:30 UTC): sesiones anónimas sin grupo y contadores de límites viejos.
select cron.schedule('pichanguita-limpieza', '30 4 * * *', $$
  select interno.limpiar_anonimos();
  delete from interno.limites_envio where ventana < now() - interval '2 days';
$$);

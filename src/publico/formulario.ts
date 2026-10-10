// Formulario de inscripción de las páginas públicas. Llama la RPC de Supabase por fetch, sin cargar la app.
// Cada campo `name="x"` viaja como `p_x`; `medios_pago` y `tipos_cancha` (casillas con el mismo name) viajan como lista.

// Debe coincidir con interno.version_consentimiento() en la base y con la fecha de /privacidad/.
export const VERSION_CONSENTIMIENTO = '2026-10-10'

const URL_API = import.meta.env.VITE_SUPABASE_URL as string | undefined
const CLAVE = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

const MENSAJES: Record<string, string> = {
  falta_consentimiento: 'Marca la casilla para aceptar el uso de tus datos.',
  consentimiento_desactualizado: 'Recarga la página e inténtalo de nuevo.',
  falta_contacto: 'Déjanos un WhatsApp o un correo para contactarte.',
  whatsapp_invalido: 'El WhatsApp no parece válido. Ejemplo: +56 9 1234 5678.',
  correo_invalido: 'El correo no parece válido.',
  datos_invalidos: 'Revisa los datos: alguno está vacío o fuera de rango.',
  demasiados_envios: 'Se enviaron muchas inscripciones desde tu conexión. Inténtalo más tarde.',
}
const MENSAJE_GENERICO = 'No pudimos enviar tu inscripción. Inténtalo de nuevo en unos minutos.'

const LISTAS = new Set(['medios_pago', 'tipos_cancha'])
const NUMEROS = new Set([
  'jugadores_por_partido', 'personas_en_grupo', 'cantidad_canchas', 'grupos_fijos',
])

function armarArgumentos(form: HTMLFormElement, msLlenado: number): Record<string, unknown> {
  const args: Record<string, unknown> = {}
  const datos = new FormData(form)
  for (const nombre of LISTAS) {
    if (form.elements.namedItem(nombre)) args[`p_${nombre}`] = datos.getAll(nombre).map(String)
  }
  for (const el of Array.from(form.elements)) {
    if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) continue
    const nombre = el.name
    if (!nombre || LISTAS.has(nombre) || nombre === 'consentimiento') continue
    const valor = el.value.trim()
    if (NUMEROS.has(nombre)) args[`p_${nombre}`] = valor === '' ? null : Number(valor)
    else args[`p_${nombre}`] = valor === '' ? null : valor
  }
  args.p_consentimiento = (form.elements.namedItem('consentimiento') as HTMLInputElement | null)?.checked === true
  args.p_consentimiento_version = VERSION_CONSENTIMIENTO
  args.p_ms_llenado = msLlenado
  return args
}

function mostrar(estado: HTMLElement, texto: string, tipo: 'ok' | 'error') {
  estado.hidden = false
  estado.textContent = texto
  estado.className = `estado ${tipo === 'ok' ? 'ok-estado' : 'error-estado'}`
  estado.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
}

export function iniciarFormulario(idForm: string, funcionRpc: string, textoExito: string) {
  const form = document.getElementById(idForm) as HTMLFormElement | null
  if (!form) return
  const boton = form.querySelector<HTMLButtonElement>('button[type="submit"]')!
  const estado = form.querySelector<HTMLElement>('[data-estado]')!
  const cargadoEn = performance.now()

  if (!URL_API || !CLAVE) {
    boton.disabled = true
    boton.textContent = 'Inscripciones abren pronto'
    return
  }

  form.addEventListener('submit', async (e) => {
    e.preventDefault()
    if (!form.reportValidity()) return
    boton.disabled = true
    estado.hidden = true
    try {
      const resp = await fetch(`${URL_API}/rest/v1/rpc/${funcionRpc}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: CLAVE },
        body: JSON.stringify(armarArgumentos(form, Math.round(performance.now() - cargadoEn))),
      })
      if (resp.ok) {
        form.reset()
        mostrar(estado, textoExito, 'ok')
        return
      }
      const cuerpo = (await resp.json().catch(() => null)) as { message?: string } | null
      mostrar(estado, MENSAJES[cuerpo?.message ?? ''] ?? MENSAJE_GENERICO, 'error')
    } catch {
      mostrar(estado, 'No hay conexión. Revisa tu internet e inténtalo de nuevo.', 'error')
    } finally {
      boton.disabled = false
    }
  })
}

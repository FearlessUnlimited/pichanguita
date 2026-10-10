import { afterAll, afterEach } from 'vitest'
import { cerrarBases } from './arnes'

afterEach(() => cerrarBases('prueba'))
afterAll(() => cerrarBases('archivo'))

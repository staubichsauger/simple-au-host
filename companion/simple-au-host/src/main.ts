import {
	combineRgb,
	InstanceBase,
	InstanceStatus,
	runEntrypoint,
	type SomeCompanionConfigField,
} from '@companion-module/base'
import http from 'node:http'
import https from 'node:https'

interface ModuleConfig {
	host: string
	port: number
}

interface SimpleAUHostKeyState {
	scaleMode: string
	noteLetter: string
	accidental: string
	title: string
	rootTitle: string
}

interface SimpleAUHostWavesTuneState {
	isEnabled: boolean
	configuredInsertCount: number
	canApplyStagedKey: boolean
	stagedKey: SimpleAUHostKeyState
	appliedKey: SimpleAUHostKeyState
	selectedSongTitle: string | null
	selectedSongIndex: number | null
	songCount: number
	previousSongKey: SimpleAUHostKeyState | null
	nextSongKey: SimpleAUHostKeyState | null
	canSelectPreviousSong: boolean
	canSelectNextSong: boolean
}

interface SimpleAUHostState {
	apiVersion: number
	appMode: string
	timestamp: string
	sessionName: string
	statusMessage: string
	isRunning: boolean
	wavesTune: SimpleAUHostWavesTuneState
}

interface SimpleAUHostCommandResponse {
	ok: boolean
	message: string
	state: SimpleAUHostState
}

interface ModuleHttpResponse<T> {
	statusCode: number
	body: T
}

const ROOT_CHOICES = [
	{ id: 'c', label: 'C' },
	{ id: 'c#', label: 'C#' },
	{ id: 'db', label: 'Db' },
	{ id: 'd', label: 'D' },
	{ id: 'd#', label: 'D#' },
	{ id: 'eb', label: 'Eb' },
	{ id: 'e', label: 'E' },
	{ id: 'f', label: 'F' },
	{ id: 'f#', label: 'F#' },
	{ id: 'gb', label: 'Gb' },
	{ id: 'g', label: 'G' },
	{ id: 'g#', label: 'G#' },
	{ id: 'ab', label: 'Ab' },
	{ id: 'a', label: 'A' },
	{ id: 'a#', label: 'A#' },
	{ id: 'bb', label: 'Bb' },
	{ id: 'b', label: 'B' },
]

const NOTE_LETTER_CHOICES = [
	{ id: 'c', label: 'C' },
	{ id: 'd', label: 'D' },
	{ id: 'e', label: 'E' },
	{ id: 'f', label: 'F' },
	{ id: 'g', label: 'G' },
	{ id: 'a', label: 'A' },
	{ id: 'b', label: 'B' },
]

const ACCIDENTAL_CHOICES = [
	{ id: 'flat', label: 'Flat' },
	{ id: 'natural', label: 'Natural' },
	{ id: 'sharp', label: 'Sharp' },
]

const SCALE_CHOICES = [
	{ id: 'chromatic', label: 'Chromatic' },
	{ id: 'major', label: 'Major' },
	{ id: 'minor', label: 'Minor' },
]

function capitalizeLabel(value: string | null | undefined): string {
	if (!value) {
		return ''
	}

	return value.charAt(0).toUpperCase() + value.slice(1)
}

function formatNoteLetter(value: string | null | undefined): string {
	return value ? value.toUpperCase() : ''
}

function optionString(value: unknown): string {
	return typeof value === 'string' ? value : ''
}

function keyMatches(
	key: SimpleAUHostKeyState | null | undefined,
	root: string,
	scaleMode: string
): boolean {
	if (!key) {
		return false
	}

	return `${key.noteLetter}${key.accidental === 'natural' ? '' : key.accidental === 'sharp' ? '#' : 'b'}` === root
		&& key.scaleMode === scaleMode
}

class SimpleAUHostModule extends InstanceBase<ModuleConfig> {
	config: ModuleConfig = {
		host: '127.0.0.1',
		port: 52719,
	}
	state: SimpleAUHostState | null = null
	pollTimer: NodeJS.Timeout | null = null

	async init(config: ModuleConfig): Promise<void> {
		this.config = config
		this.updateActions()
		this.updateFeedbacks()
		this.updateVariableDefinitions()
		this.updateVariableValues()
		this.startPolling()
	}

	async destroy(): Promise<void> {
		this.stopPolling()
	}

	async configUpdated(config: ModuleConfig): Promise<void> {
		this.config = config
		this.startPolling()
	}

	getConfigFields(): SomeCompanionConfigField[] {
		return [
			{
				type: 'textinput',
				id: 'host',
				label: 'SimpleAUHost Host',
				width: 8,
				default: '127.0.0.1',
			},
			{
				type: 'number',
				id: 'port',
				label: 'SimpleAUHost Port',
				width: 4,
				min: 1,
				max: 65535,
				default: 52719,
			},
		]
	}

	private updateActions(): void {
		this.setActionDefinitions({
			set_enabled: {
				name: 'Set Waves Tune On/Off',
				options: [
					{
						type: 'dropdown',
						id: 'enabled',
						label: 'State',
						default: 'on',
						choices: [
							{ id: 'on', label: 'On' },
							{ id: 'off', label: 'Off' },
						],
					},
				],
				callback: async (event) => {
					await this.postAction('/api/v1/actions/waves-tune/enabled', {
						enabled: event.options.enabled === 'on',
					})
				},
			},
			toggle_enabled: {
				name: 'Toggle Waves Tune On/Off',
				options: [],
				callback: async () => {
					await this.postAction('/api/v1/actions/waves-tune/toggle-enabled')
				},
			},
			set_staged_key: {
				name: 'Set Staged Key',
				options: [
					{
						type: 'dropdown',
						id: 'root',
						label: 'Root',
						default: 'c',
						choices: ROOT_CHOICES,
					},
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: async (event) => {
					await this.postAction('/api/v1/actions/waves-tune/staged-key', {
						root: event.options.root,
						scaleMode: event.options.scaleMode,
					})
				},
			},
			set_note_letter: {
				name: 'Set Note Letter',
				options: [
					{
						type: 'dropdown',
						id: 'noteLetter',
						label: 'Note Letter',
						default: 'c',
						choices: NOTE_LETTER_CHOICES,
					},
				],
				callback: async (event) => {
					await this.postAction('/api/v1/actions/waves-tune/note-letter', {
						noteLetter: event.options.noteLetter,
					})
				},
			},
			set_accidental: {
				name: 'Set Accidental',
				options: [
					{
						type: 'dropdown',
						id: 'accidental',
						label: 'Accidental',
						default: 'natural',
						choices: ACCIDENTAL_CHOICES,
					},
				],
				callback: async (event) => {
					await this.postAction('/api/v1/actions/waves-tune/accidental', {
						accidental: event.options.accidental,
					})
				},
			},
			set_scale_mode: {
				name: 'Set Scale Mode',
				options: [
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: async (event) => {
					await this.postAction('/api/v1/actions/waves-tune/scale-mode', {
						scaleMode: event.options.scaleMode,
					})
				},
			},
			apply_staged_key: {
				name: 'Apply Staged Key',
				options: [],
				callback: async () => {
					await this.postAction('/api/v1/actions/waves-tune/apply')
				},
			},
			key_panic: {
				name: 'Key Panic',
				options: [],
				callback: async () => {
					await this.postAction('/api/v1/actions/waves-tune/panic')
				},
			},
			next_song: {
				name: 'Next Song',
				options: [],
				callback: async () => {
					await this.postAction('/api/v1/actions/waves-tune/step-song', { direction: 1 })
				},
			},
			previous_song: {
				name: 'Previous Song',
				options: [],
				callback: async () => {
					await this.postAction('/api/v1/actions/waves-tune/step-song', { direction: -1 })
				},
			},
		})
	}

	private updateFeedbacks(): void {
		this.setFeedbackDefinitions({
			waves_tune_enabled: {
				name: 'Waves Tune Enabled',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(32, 128, 64),
					color: combineRgb(255, 255, 255),
				},
				options: [],
				callback: () => {
					return this.state?.wavesTune.isEnabled ?? false
				},
			},
			engine_running: {
				name: 'Engine Running',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(0, 120, 212),
					color: combineRgb(255, 255, 255),
				},
				options: [],
				callback: () => {
					return this.state?.isRunning ?? false
				},
			},
			can_apply_staged_key: {
				name: 'Staged Key Differs From Applied Key',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(160, 96, 16),
					color: combineRgb(255, 255, 255),
				},
				options: [],
				callback: () => {
					return this.state?.wavesTune.canApplyStagedKey ?? false
				},
			},
			staged_note_letter_is: {
				name: 'Staged Note Letter Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(0, 120, 212),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'noteLetter',
						label: 'Note Letter',
						default: 'c',
						choices: NOTE_LETTER_CHOICES,
					},
				],
				callback: (feedback) => {
					return this.state?.wavesTune.stagedKey.noteLetter === optionString(feedback.options.noteLetter)
				},
			},
			staged_accidental_is: {
				name: 'Staged Accidental Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(160, 96, 16),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'accidental',
						label: 'Accidental',
						default: 'natural',
						choices: ACCIDENTAL_CHOICES,
					},
				],
				callback: (feedback) => {
					return this.state?.wavesTune.stagedKey.accidental === optionString(feedback.options.accidental)
				},
			},
			staged_scale_mode_is: {
				name: 'Staged Scale Mode Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(32, 128, 64),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: (feedback) => {
					return this.state?.wavesTune.stagedKey.scaleMode === optionString(feedback.options.scaleMode)
				},
			},
			active_key_is: {
				name: 'Active Key Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(96, 48, 160),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'root',
						label: 'Root',
						default: 'c',
						choices: ROOT_CHOICES,
					},
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: (feedback) => {
					return keyMatches(
						this.state?.wavesTune.appliedKey,
						optionString(feedback.options.root),
						optionString(feedback.options.scaleMode)
					)
				},
			},
			previous_song_key_is: {
				name: 'Previous Song Key Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(140, 80, 0),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'root',
						label: 'Root',
						default: 'c',
						choices: ROOT_CHOICES,
					},
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: (feedback) => {
					return keyMatches(
						this.state?.wavesTune.previousSongKey,
						optionString(feedback.options.root),
						optionString(feedback.options.scaleMode)
					)
				},
			},
			next_song_key_is: {
				name: 'Next Song Key Is',
				type: 'boolean',
				defaultStyle: {
					bgcolor: combineRgb(140, 0, 80),
					color: combineRgb(255, 255, 255),
				},
				options: [
					{
						type: 'dropdown',
						id: 'root',
						label: 'Root',
						default: 'c',
						choices: ROOT_CHOICES,
					},
					{
						type: 'dropdown',
						id: 'scaleMode',
						label: 'Scale',
						default: 'major',
						choices: SCALE_CHOICES,
					},
				],
				callback: (feedback) => {
					return keyMatches(
						this.state?.wavesTune.nextSongKey,
						optionString(feedback.options.root),
						optionString(feedback.options.scaleMode)
					)
				},
			},
		})
	}

	private updateVariableDefinitions(): void {
		this.setVariableDefinitions([
			{ variableId: 'session_name', name: 'Current session name' },
			{ variableId: 'status_message', name: 'Current status message' },
			{ variableId: 'engine_running', name: 'Engine running flag' },
			{ variableId: 'waves_tune_enabled', name: 'Waves Tune enabled flag' },
			{ variableId: 'active_key_title', name: 'Currently active key title' },
			{ variableId: 'staged_key_title', name: 'Staged key title' },
			{ variableId: 'applied_key_title', name: 'Applied key title' },
			{ variableId: 'staged_note_letter', name: 'Staged note letter' },
			{ variableId: 'staged_scale_mode', name: 'Staged scale mode' },
			{ variableId: 'staged_accidental', name: 'Staged accidental' },
			{ variableId: 'selected_song_title', name: 'Selected song title' },
			{ variableId: 'previous_song_key_title', name: 'Previous song key title' },
			{ variableId: 'next_song_key_title', name: 'Next song key title' },
			{ variableId: 'song_position', name: 'Selected song position (1-based)' },
			{ variableId: 'song_count', name: 'Song count' },
		])
	}

	private updateVariableValues(): void {
		const songPosition =
			this.state?.wavesTune.selectedSongIndex !== null && this.state?.wavesTune.selectedSongIndex !== undefined
				? String(this.state.wavesTune.selectedSongIndex + 1)
				: ''

		this.setVariableValues({
			session_name: this.state?.sessionName ?? '',
			status_message: this.state?.statusMessage ?? '',
			engine_running: this.state?.isRunning ? 'true' : 'false',
			waves_tune_enabled: this.state?.wavesTune.isEnabled ? 'true' : 'false',
			active_key_title: this.state?.wavesTune.appliedKey.title ?? '',
			staged_key_title: this.state?.wavesTune.stagedKey.title ?? '',
			applied_key_title: this.state?.wavesTune.appliedKey.title ?? '',
			staged_note_letter: formatNoteLetter(this.state?.wavesTune.stagedKey.noteLetter),
			staged_scale_mode: capitalizeLabel(this.state?.wavesTune.stagedKey.scaleMode),
			staged_accidental: capitalizeLabel(this.state?.wavesTune.stagedKey.accidental),
			selected_song_title: this.state?.wavesTune.selectedSongTitle ?? '',
			previous_song_key_title: this.state?.wavesTune.previousSongKey?.title ?? '',
			next_song_key_title: this.state?.wavesTune.nextSongKey?.title ?? '',
			song_position: songPosition,
			song_count: this.state ? String(this.state.wavesTune.songCount) : '0',
		})
		this.checkFeedbacks()
	}

	private startPolling(): void {
		this.stopPolling()
		void this.pollState()
		this.pollTimer = setInterval(() => {
			void this.pollState()
		}, 1000)
	}

	private stopPolling(): void {
		if (this.pollTimer) {
			clearInterval(this.pollTimer)
			this.pollTimer = null
		}
	}

	private async pollState(): Promise<void> {
		if (!this.config.host || !this.config.port) {
			this.state = null
			this.updateStatus(InstanceStatus.BadConfig, 'Configure the SimpleAUHost address first.')
			this.updateVariableValues()
			return
		}

		try {
			const response = await this.requestJson<SimpleAUHostState>('/api/v1/state')
			this.state = response.body
			this.updateStatus(InstanceStatus.Ok)
			this.updateVariableValues()
		} catch (error) {
			this.state = null
			this.updateStatus(InstanceStatus.Disconnected, this.describeError(error))
			this.updateVariableValues()
		}
	}

	private async postAction(path: string, payload?: Record<string, unknown>): Promise<void> {
		try {
			const response = await this.requestJson<SimpleAUHostCommandResponse>(path, {
				method: 'POST',
				body: payload ?? {},
			})

			if (!response.body.ok) {
				throw new Error(response.body.message || `HTTP ${response.statusCode}`)
			}

			this.state = response.body.state
			this.updateStatus(InstanceStatus.Ok)
			this.updateVariableValues()
		} catch (error) {
			const message = this.describeError(error)
			this.log('error', `SimpleAUHost action failed: ${message}`)
			this.updateStatus(InstanceStatus.UnknownError, message)
			await this.pollState()
		}
	}

	private async requestJson<T>(
		path: string,
		options?: {
			method?: 'GET' | 'POST'
			body?: Record<string, unknown>
		}
	): Promise<ModuleHttpResponse<T>> {
		const url = new URL(this.url(path))
		const transport = url.protocol === 'https:' ? https : http
		const requestBody = options?.body ? JSON.stringify(options.body) : undefined
		const method = options?.method ?? 'GET'

		return await new Promise((resolve, reject) => {
			const request = transport.request(
				url,
				{
					method,
					headers: requestBody
						? {
								'Content-Type': 'application/json',
								'Content-Length': Buffer.byteLength(requestBody).toString(),
							}
						: undefined,
				},
				(response) => {
					const chunks: Buffer[] = []

					response.on('data', (chunk: Buffer | string) => {
						chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
					})

					response.on('end', () => {
						const rawBody = Buffer.concat(chunks).toString('utf8')
						const statusCode = response.statusCode ?? 0

						if (statusCode < 200 || statusCode >= 300) {
							reject(new Error(`HTTP ${statusCode}${rawBody ? `: ${rawBody}` : ''}`))
							return
						}

						if (!rawBody) {
							reject(new Error('SimpleAUHost returned an empty response body.'))
							return
						}

						try {
							resolve({
								statusCode,
								body: JSON.parse(rawBody) as T,
							})
						} catch {
							reject(new Error('SimpleAUHost returned invalid JSON.'))
						}
					})
				}
			)

			request.setTimeout(3000, () => {
				request.destroy(new Error('Request timed out after 3000ms.'))
			})

			request.on('error', (error) => {
				reject(error)
			})

			if (requestBody) {
				request.write(requestBody)
			}

			request.end()
		})
	}

	private url(path: string): string {
		return `http://${this.config.host}:${this.config.port}${path}`
	}

	private describeError(error: unknown): string {
		if (error && typeof error === 'object' && 'code' in error) {
			const code = String((error as { code: unknown }).code)
			if (code === 'ECONNREFUSED') {
				return 'Connection refused. Verify SimpleAUHost is open in Multi Track mode and listening on the configured port.'
			}
			if (code === 'ETIMEDOUT') {
				return 'Connection timed out.'
			}
		}

		if (error instanceof Error && error.message) {
			return error.message
		}
		return 'Unknown error'
	}
}

runEntrypoint(SimpleAUHostModule, [])

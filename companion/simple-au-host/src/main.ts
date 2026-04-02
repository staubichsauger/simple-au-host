import {
	combineRgb,
	InstanceBase,
	InstanceStatus,
	Regex,
	runEntrypoint,
	type SomeCompanionConfigField,
} from '@companion-module/base'

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

const SCALE_CHOICES = [
	{ id: 'chromatic', label: 'Chromatic' },
	{ id: 'major', label: 'Major' },
	{ id: 'minor', label: 'Minor' },
]

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
				label: 'SimpleAUHost IP',
				width: 8,
				regex: Regex.IP,
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
		})
	}

	private updateVariableDefinitions(): void {
		this.setVariableDefinitions([
			{ variableId: 'session_name', name: 'Current session name' },
			{ variableId: 'status_message', name: 'Current status message' },
			{ variableId: 'engine_running', name: 'Engine running flag' },
			{ variableId: 'waves_tune_enabled', name: 'Waves Tune enabled flag' },
			{ variableId: 'staged_key_title', name: 'Staged key title' },
			{ variableId: 'applied_key_title', name: 'Applied key title' },
			{ variableId: 'selected_song_title', name: 'Selected song title' },
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
			staged_key_title: this.state?.wavesTune.stagedKey.title ?? '',
			applied_key_title: this.state?.wavesTune.appliedKey.title ?? '',
			selected_song_title: this.state?.wavesTune.selectedSongTitle ?? '',
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
			const response = await fetch(this.url('/api/v1/state'), {
				signal: AbortSignal.timeout(3000),
			})

			if (!response.ok) {
				throw new Error(`HTTP ${response.status}`)
			}

			this.state = (await response.json()) as SimpleAUHostState
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
			const response = await fetch(this.url(path), {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
				},
				body: payload ? JSON.stringify(payload) : '{}',
				signal: AbortSignal.timeout(3000),
			})

			const body = (await response.json()) as SimpleAUHostCommandResponse
			if (!response.ok || !body.ok) {
				throw new Error(body.message || `HTTP ${response.status}`)
			}

			this.state = body.state
			this.updateStatus(InstanceStatus.Ok)
			this.updateVariableValues()
		} catch (error) {
			const message = this.describeError(error)
			this.log('error', `SimpleAUHost action failed: ${message}`)
			this.updateStatus(InstanceStatus.UnknownError, message)
			await this.pollState()
		}
	}

	private url(path: string): string {
		return `http://${this.config.host}:${this.config.port}${path}`
	}

	private describeError(error: unknown): string {
		if (error instanceof Error && error.message) {
			return error.message
		}
		return 'Unknown error'
	}
}

runEntrypoint(SimpleAUHostModule, [])

class CircularProgress extends HTMLElement {
    constructor() {
        super();
        this.attachShadow({ mode: 'open' });
        this._progress = 0;
        this.radius = 90;
        this.circumference = 2 * Math.PI * this.radius;
    }

    static get observedAttributes() {
        return ['progress'];
    }

    get progress() {
        return this._progress;
    }

    attributeChangedCallback(name, oldValue, newValue) {
        if (name === 'progress' && oldValue !== newValue) {
            this._progress = Math.max(0, Math.min(100, parseFloat(newValue) || 0));
            this.updateProgress();
        }
   }

    connectedCallback() {
        this.render();
    }

    render() {
        this.shadowRoot.innerHTML = `
            <slot></slot>
            <svg
                width="200"
                height="200"
                viewBox="-25 -25 250 250"
                style="transform: rotate(-90deg)"
            >
                <!-- Background circle -->
                <circle
                    r="${this.radius}"
                    cx="100"
                    cy="100"
                    fill="transparent"
                    stroke="#e0e0e0"
                    stroke-width="16px"
                    stroke-dasharray="${this.circumference}px"
                    stroke-dashoffset="${this.circumference}px"
                ></circle>

                <!-- Progress circle -->
                <circle
                    id="progress-circle"
                    r="${this.radius}"
                    cx="100"
                    cy="100"
                    fill="transparent"
                    stroke="#6bdba7"
                    stroke-width="16px"
                    stroke-linecap="round"
                    stroke-dasharray="${this.circumference}px"
                    style="transition: stroke-dashoffset 0.1s ease-in-out"
                ></circle>

                <!-- Progress text -->
                <text
                    id="progress-text"
                    x="44px"
                    y="115px"
                    fill="#6bdba7"
                    font-size="52px"
                    font-weight="bold"
                    style="transform:rotate(90deg) translate(0px, -196px)"
                ></text>
            </svg>
        `;
    }

    updateProgress() {
        if (!this.shadowRoot) return;

        const progressCircle = this.shadowRoot.getElementById('progress-circle');
        const progressText = this.shadowRoot.getElementById('progress-text');

        if (progressCircle && progressText) {
            // Calculate stroke-dashoffset based on progress
            const offset = this.circumference - (this._progress / 100) * this.circumference;
            progressCircle.style.strokeDashoffset = `${offset}px`;

            // Update text
            progressText.textContent = `${Math.round(this._progress)}%`;
        }
    }
}

// Register the custom element
customElements.define('circular-progress', CircularProgress);

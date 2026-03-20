/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * GitHub App post-installation setup page
 *
 * Shown after a user installs the GitHub App. Displays:
 * - A button to create a new git-repository-backed grove
 * - A list of existing groves with GitHub remotes and their installation status
 * - Auto-discovers and associates installations with matching groves
 */

import { LitElement, html, css, nothing } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { apiFetch } from '../../client/api.js';

import type { PageData, Grove, GitHubAppGroveStatus } from '../../shared/types.js';

type GitHubGrove = Grove;

@customElement('scion-page-github-app-setup')
export class ScionPageGitHubAppSetup extends LitElement {
  @property({ type: Object })
  pageData?: PageData;

  @state()
  private loading = true;

  @state()
  private discovering = false;

  @state()
  private groves: GitHubGrove[] = [];

  @state()
  private error: string | null = null;

  @state()
  private discoveryResult: { total: number; matched: number } | null = null;

  @state()
  private checkingGroves = new Set<string>();

  override connectedCallback(): void {
    super.connectedCallback();

    this.initPage();
  }

  private async initPage(): Promise<void> {
    this.loading = true;
    try {
      // Run discovery first to sync installations and auto-match groves,
      // then load groves to show the updated state.
      await this.discoverInstallations();
      await this.loadGroves();
    } catch (err) {
      console.error('Failed to initialize setup page:', err);
      this.error = err instanceof Error ? err.message : 'Failed to load page data';
    } finally {
      this.loading = false;
    }
  }

  private async discoverInstallations(): Promise<void> {
    this.discovering = true;
    try {
      const res = await apiFetch('/api/v1/github-app/installations/discover', {
        method: 'POST',
      });
      if (res.ok) {
        const data = (await res.json()) as {
          installations: Array<{ matched_groves?: string[] }>;
          total: number;
        };
        let matched = 0;
        for (const inst of data.installations) {
          if (inst.matched_groves?.length) {
            matched += inst.matched_groves.length;
          }
        }
        this.discoveryResult = { total: data.total, matched };
      }
    } catch (err) {
      console.warn('Installation discovery failed:', err);
      // Non-fatal — continue loading groves
    } finally {
      this.discovering = false;
    }
  }

  private async loadGroves(): Promise<void> {
    const res = await apiFetch('/api/v1/groves?mine=true');
    if (!res.ok) {
      throw new Error(`Failed to fetch groves: HTTP ${res.status}`);
    }
    const data = (await res.json()) as { groves: Grove[] };
    // Filter to groves that have a GitHub remote URL
    this.groves = (data.groves || []).filter(
      (g) => g.gitRemote && this.isGitHubUrl(g.gitRemote)
    );
  }

  private isGitHubUrl(url: string): boolean {
    return /github\.com/i.test(url);
  }

  private async checkGroveStatus(grove: GitHubGrove): Promise<void> {
    if (!grove.githubInstallationId) return;

    this.checkingGroves = new Set([...this.checkingGroves, grove.id]);
    try {
      const res = await apiFetch(`/api/v1/groves/${grove.id}/github-status`, {
        method: 'POST',
      });
      if (res.ok) {
        const data = (await res.json()) as {
          status?: GitHubAppGroveStatus;
        };
        // Update the grove in our list
        this.groves = this.groves.map((g) =>
          g.id === grove.id
            ? { ...g, githubAppStatus: data.status || g.githubAppStatus }
            : g
        );
      }
    } catch (err) {
      console.error('Failed to check grove status:', err);
    } finally {
      const next = new Set(this.checkingGroves);
      next.delete(grove.id);
      this.checkingGroves = next;
    }
  }

  private async checkAllGroves(): Promise<void> {
    const grovesWithInstallation = this.groves.filter(
      (g) => g.githubInstallationId
    );
    await Promise.allSettled(
      grovesWithInstallation.map((g) => this.checkGroveStatus(g))
    );
  }

  private navigateTo(path: string): void {
    window.history.pushState({}, '', path);
    window.dispatchEvent(new PopStateEvent('popstate'));
  }

  private renderStatusBadge(grove: GitHubGrove) {
    if (!grove.githubInstallationId) {
      return html`<sl-badge variant="neutral">No Installation</sl-badge>`;
    }

    const status = grove.githubAppStatus;
    if (!status) {
      return html`<sl-badge variant="neutral">Unchecked</sl-badge>`;
    }

    switch (status.state) {
      case 'ok':
        return html`<sl-badge variant="success">Connected</sl-badge>`;
      case 'degraded':
        return html`<sl-badge variant="warning">Degraded</sl-badge>`;
      case 'error':
        return html`<sl-badge variant="danger">Error</sl-badge>`;
      default:
        return html`<sl-badge variant="neutral">Unchecked</sl-badge>`;
    }
  }

  private extractRepoName(url: string): string {
    try {
      const cleaned = url
        .replace(/^(https?:\/\/|ssh:\/\/|git:\/\/|git@)/, '')
        .replace(':', '/')
        .replace(/\.git$/, '');
      const parts = cleaned.split('/');
      if (parts.length >= 2) {
        return `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
      }
      return parts[parts.length - 1] || url;
    } catch {
      return url;
    }
  }

  static override styles = css`
    :host {
      display: block;
    }

    .page-header {
      margin-bottom: 1.5rem;
    }

    .page-header h1 {
      font-size: 1.5rem;
      font-weight: 700;
      color: var(--scion-text, #1e293b);
      margin: 0 0 0.25rem 0;
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }

    .page-header h1 sl-icon {
      color: var(--scion-primary, #3b82f6);
      font-size: 1.5rem;
    }

    .page-header p {
      color: var(--scion-text-muted, #64748b);
      margin: 0;
      font-size: 0.875rem;
    }

    .success-banner {
      background: var(--sl-color-success-50, #f0fdf4);
      border: 1px solid var(--sl-color-success-200, #bbf7d0);
      border-radius: var(--scion-radius, 0.5rem);
      padding: 0.75rem 1rem;
      margin-bottom: 1.5rem;
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      color: var(--sl-color-success-700, #15803d);
      font-size: 0.875rem;
    }

    .success-banner sl-icon {
      flex-shrink: 0;
      margin-top: 0.125rem;
    }

    .error-banner {
      background: var(--sl-color-danger-50, #fef2f2);
      border: 1px solid var(--sl-color-danger-200, #fecaca);
      border-radius: var(--scion-radius, 0.5rem);
      padding: 0.75rem 1rem;
      margin-bottom: 1.5rem;
      display: flex;
      align-items: flex-start;
      gap: 0.5rem;
      color: var(--sl-color-danger-700, #b91c1c);
      font-size: 0.875rem;
    }

    .error-banner sl-icon {
      flex-shrink: 0;
      margin-top: 0.125rem;
    }

    .actions-card {
      background: var(--scion-surface, #ffffff);
      border: 1px solid var(--scion-border, #e2e8f0);
      border-radius: var(--scion-radius-lg, 0.75rem);
      padding: 1.5rem;
      margin-bottom: 1.5rem;
    }

    .actions-card h2 {
      font-size: 1rem;
      font-weight: 600;
      color: var(--scion-text, #1e293b);
      margin: 0 0 0.5rem 0;
    }

    .actions-card p {
      color: var(--scion-text-muted, #64748b);
      font-size: 0.875rem;
      margin: 0 0 1rem 0;
    }

    .groves-card {
      background: var(--scion-surface, #ffffff);
      border: 1px solid var(--scion-border, #e2e8f0);
      border-radius: var(--scion-radius-lg, 0.75rem);
      padding: 1.5rem;
    }

    .groves-card h2 {
      font-size: 1rem;
      font-weight: 600;
      color: var(--scion-text, #1e293b);
      margin: 0 0 0.25rem 0;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .groves-card .subtitle {
      color: var(--scion-text-muted, #64748b);
      font-size: 0.875rem;
      margin: 0 0 1rem 0;
    }

    .grove-list {
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }

    .grove-item {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 0.75rem 1rem;
      border: 1px solid var(--scion-border, #e2e8f0);
      border-radius: var(--scion-radius, 0.5rem);
      background: var(--scion-bg-subtle, #f8fafc);
    }

    .grove-info {
      display: flex;
      flex-direction: column;
      gap: 0.25rem;
      min-width: 0;
    }

    .grove-name {
      font-weight: 600;
      color: var(--scion-text, #1e293b);
      font-size: 0.875rem;
    }

    .grove-repo {
      color: var(--scion-text-muted, #64748b);
      font-size: 0.75rem;
      font-family: var(--scion-font-mono, monospace);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .grove-status {
      display: flex;
      align-items: center;
      gap: 0.5rem;
    }

    .grove-actions {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-shrink: 0;
    }

    .empty-state {
      text-align: center;
      padding: 2rem 1rem;
      color: var(--scion-text-muted, #64748b);
    }

    .empty-state sl-icon {
      font-size: 2rem;
      margin-bottom: 0.75rem;
      display: block;
    }

    .empty-state p {
      margin: 0 0 0.5rem 0;
      font-size: 0.875rem;
    }

    .loading-state {
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 3rem;
      gap: 0.75rem;
      color: var(--scion-text-muted, #64748b);
    }
  `;

  override render() {
    if (this.loading) {
      return html`
        <div class="page-header">
          <h1>
            <sl-icon name="github"></sl-icon>
            GitHub App Setup
          </h1>
        </div>
        <div class="loading-state">
          <sl-spinner></sl-spinner>
          <span>${this.discovering ? 'Discovering installations...' : 'Loading...'}</span>
        </div>
      `;
    }

    return html`
      <div class="page-header">
        <h1>
          <sl-icon name="github"></sl-icon>
          GitHub App Setup
        </h1>
        <p>Your GitHub App installation has been recorded. Set up groves for your repositories below.</p>
      </div>

      ${this.error
        ? html`
            <div class="error-banner">
              <sl-icon name="exclamation-triangle"></sl-icon>
              <span>${this.error}</span>
            </div>
          `
        : nothing}

      ${this.discoveryResult && this.discoveryResult.matched > 0
        ? html`
            <div class="success-banner">
              <sl-icon name="check-circle"></sl-icon>
              <span>
                Auto-matched ${this.discoveryResult.matched}
                grove${this.discoveryResult.matched !== 1 ? 's' : ''} with GitHub App
                installation${this.discoveryResult.total !== 1 ? 's' : ''}.
              </span>
            </div>
          `
        : nothing}

      <div class="actions-card">
        <h2>Get Started</h2>
        <p>Create a new grove linked to a GitHub repository to start running agents.</p>
        <sl-button
          variant="primary"
          @click=${() => this.navigateTo('/groves/new')}
        >
          <sl-icon slot="prefix" name="folder-plus"></sl-icon>
          Create New Grove
        </sl-button>
      </div>

      <div class="groves-card">
        <h2>
          <span>GitHub Groves</span>
          ${this.groves.some((g) => g.githubInstallationId)
            ? html`
                <sl-button
                  size="small"
                  variant="default"
                  @click=${() => this.checkAllGroves()}
                  ?disabled=${this.checkingGroves.size > 0}
                >
                  <sl-icon slot="prefix" name="arrow-repeat"></sl-icon>
                  Check All
                </sl-button>
              `
            : nothing}
        </h2>
        <p class="subtitle">
          Groves linked to GitHub repositories.
          ${this.groves.length > 0
            ? 'Verify installations are working or configure them in grove settings.'
            : ''}
        </p>

        ${this.groves.length > 0
          ? html`
              <div class="grove-list">
                ${this.groves.map((grove) => this.renderGroveItem(grove))}
              </div>
            `
          : html`
              <div class="empty-state">
                <sl-icon name="folder-x"></sl-icon>
                <p>No groves with GitHub repositories found.</p>
                <p>Create a new grove to get started.</p>
              </div>
            `}
      </div>
    `;
  }

  private renderGroveItem(grove: GitHubGrove) {
    const checking = this.checkingGroves.has(grove.id);

    return html`
      <div class="grove-item">
        <div class="grove-info">
          <span class="grove-name">${grove.name}</span>
          <span class="grove-repo">${this.extractRepoName(grove.gitRemote || '')}</span>
        </div>
        <div class="grove-actions">
          <div class="grove-status">
            ${checking
              ? html`<sl-spinner style="font-size: 1rem;"></sl-spinner>`
              : this.renderStatusBadge(grove)}
          </div>
          ${grove.githubInstallationId && !checking
            ? html`
                <sl-button
                  size="small"
                  variant="text"
                  @click=${() => this.checkGroveStatus(grove)}
                  title="Verify installation"
                >
                  <sl-icon name="arrow-repeat"></sl-icon>
                </sl-button>
              `
            : nothing}
          <sl-button
            size="small"
            variant="default"
            @click=${() => this.navigateTo(`/groves/${grove.id}/settings`)}
          >
            <sl-icon slot="prefix" name="gear"></sl-icon>
            Settings
          </sl-button>
        </div>
      </div>
    `;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'scion-page-github-app-setup': ScionPageGitHubAppSetup;
  }
}

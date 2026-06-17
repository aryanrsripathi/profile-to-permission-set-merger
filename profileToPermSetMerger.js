import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent }    from 'lightning/platformShowToastEvent';
import getProfiles           from '@salesforce/apex/PermSetMergerController.getProfiles';
import getPermissionSets     from '@salesforce/apex/PermSetMergerController.getPermissionSets';
import getProfileSummary     from '@salesforce/apex/PermSetMergerController.getProfileSummary';
import mergePermissions      from '@salesforce/apex/PermSetMergerController.mergePermissions';
import checkDeployStatus     from '@salesforce/apex/PermSetMergerController.checkDeployStatus';

// All 20 permission categories
const APP_CATEGORIES = [
    { label: 'Assigned Apps',                         value: 'assignedApps',                     description: 'Apps visible in the app menu',                                        checked: true },
    { label: 'Assigned Connected Apps',               value: 'assignedConnectedApps',             description: 'Connected apps visible in the app menu',                              checked: true },
    { label: 'Object Settings (Objects + Fields)',    value: 'objectSettings',                    description: 'Object CRUD + all field-level read/edit access',                      checked: true },
    { label: 'App Permissions',                       value: 'appPermissions',                    description: 'App-specific actions such as "Manage Call Centers"',                  checked: true },
    { label: 'Apex Class Access',                     value: 'apexClassAccess',                   description: 'Permissions to execute Apex classes',                                 checked: true },
    { label: 'Visualforce Page Access',               value: 'visualforcePageAccess',             description: 'Permissions to execute Visualforce pages',                            checked: true },
    { label: 'External Data Source Access',           value: 'externalDataSourceAccess',          description: 'Authenticate against external data sources',                          checked: true },
    { label: 'Flow Access',                           value: 'flowAccess',                        description: 'Permissions to execute Flows',                                        checked: true },
    { label: 'Named Credential Access',               value: 'namedCredentialAccess',             description: 'Authenticate against named credentials',                              checked: true },
    { label: 'External Credential Principal Access',  value: 'externalCredentialPrincipalAccess', description: 'External credential principal mappings (Metadata API only)',          checked: false },
    { label: 'Data Category Visibility',              value: 'dataCategoryVisibility',            description: 'Data category access (Metadata API only)',                            checked: false },
    { label: 'Service Presence Statuses Access',      value: 'servicePresenceStatusAccess',       description: 'Access to Service Presence Statuses',                                 checked: true },
    { label: 'Custom Permissions',                    value: 'customPermissions',                 description: 'Custom processes and app permissions',                                checked: true },
    { label: 'Custom Metadata Types',                 value: 'customMetadataTypes',               description: 'Access to custom metadata types',                                     checked: true },
    { label: 'Custom Setting Definitions',            value: 'customSettingDefinitions',          description: 'Access to custom settings',                                           checked: true },
    { label: 'Organization-Wide Email Address Access',value: 'orgWideEmailAddressAccess',         description: 'Org-wide email address (Metadata API only)',                          checked: false },
    { label: 'Standard Invocable Action Type Access', value: 'standardInvocableActionAccess',     description: 'Standard invocable actions (Metadata API only)',                      checked: false },
    { label: 'Email-to-Case Routing Address Access',  value: 'emailToCaseRoutingAccess',          description: 'Email-to-Case routing address (Metadata API only)',                   checked: false },
];

const SYSTEM_CATEGORIES = [
    { label: 'System Permissions',  value: 'systemPermissions',     description: 'Permissions to perform actions that apply across apps, such as "Modify All Data"', checked: true },
    { label: 'Service Providers',   value: 'serviceProviderAccess', description: 'Permissions that let users switch to other websites using single sign-on (granted via Connected App access)', checked: true },
];

export default class ProfileToPermSetMerger extends LightningElement {

    @track currentStep      = '1';
    @track profileOptions   = [];
    @track permSetOptions   = [];
    @track profileSummary   = null;

    @track selectedProfileId    = null;   // Salesforce Profile Id
    @track selectedProfileLabel = '';     // Display name
    @track selectedPermSet      = '';     // PermissionSet API Name

    // Searchable picker state (Steps 1 & 2)
    @track profileSearch        = '';
    @track profileDropdownOpen  = false;
    @track permSetSearch        = '';
    @track permSetLabel         = '';
    @track permSetDropdownOpen  = false;

    sessionId = null;                       // Metadata API session from VF page

    @track appCategories    = APP_CATEGORIES.map(c => ({ ...c }));
    @track systemCategories = SYSTEM_CATEGORIES.map(c => ({ ...c }));
    @track categoryFilter   = '';          // live search on the category step

    @track isMerging        = false;
    @track deployJobId      = null;
    @track deployState      = 'Pending';
    @track deployDone       = false;
    @track deploySuccess    = false;
    @track deployError      = '';
    @track deployedCount    = 0;
    @track totalComponents  = 0;
    @track mergedCategories = [];
    @track skippedItems     = [];

    _pollTimer = null;

    // ── Wires ─────────────────────────────────────────────────────────────────
    @wire(getProfiles)
    wiredProfiles({ data, error }) {
        if (data)  this.profileOptions = data;
        if (error) this.toast('Error', 'Failed to load profiles: ' + this.errMsg(error), 'error');
    }

    @wire(getPermissionSets)
    wiredPermSets({ data, error }) {
        if (data)  this.permSetOptions = data;
        if (error) this.toast('Error', 'Failed to load permission sets: ' + this.errMsg(error), 'error');
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────────
    connectedCallback() {
        this._onMessage = (e) => {
            // The VF session loader runs on a *.vf.force.com / *.visualforce.com
            // origin, which is NOT the same origin as this Lightning host. So we
            // can't require same-origin — instead allow any Salesforce-owned
            // origin as defense-in-depth, then validate the message shape.
            const o = (e && e.origin) ? e.origin : '';
            const trusted =
                o.endsWith('.force.com') ||
                o.endsWith('.visualforce.com') ||
                o.endsWith('.salesforce.com') ||
                o.endsWith('.salesforce-setup.com');
            if (!trusted) return;
            if (e.data && e.data.type === 'PERM_MERGER_SESSION' && e.data.sessionId) {
                this.sessionId = e.data.sessionId;
            }
        };
        window.addEventListener('message', this._onMessage);
    }

    disconnectedCallback() {
        if (this._pollTimer) clearInterval(this._pollTimer);
        if (this._onMessage) window.removeEventListener('message', this._onMessage);
    }

    // ── Display helpers ──────────────────────────────────────────────────────
    // The template binds {selectedProfile}; expose the human-readable label.
    get selectedProfile() {
        return this.selectedProfileLabel || this.selectedProfileId || '';
    }

    // ── Step visibility ────────────────────────────────────────────────────────
    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get isStep4() { return this.currentStep === '4'; }

    get step1Disabled() { return !this.selectedProfileId; }
    get step2Disabled() { return !this.selectedPermSet; }

    get allCats()      { return [...this.appCategories, ...this.systemCategories]; }
    get selectedCount(){ return this.allCats.filter(c => c.checked).length; }
    get totalCount()   { return this.allCats.length; }
    get mergeDisabled(){ return this.selectedCount === 0 || this.isMerging; }
    get mergeLabel()   { return this.isMerging ? 'Deploying…' : `Merge & Deploy (${this.selectedCount} categories)`; }

    // ── Category search / filtering (Step 3) ─────────────────────────────────────
    _matchFilter(c) {
        const q = (this.categoryFilter || '').trim().toLowerCase();
        if (!q) return true;
        return (c.label && c.label.toLowerCase().includes(q)) ||
               (c.description && c.description.toLowerCase().includes(q));
    }
    get filteredAppCategories()    { return this.appCategories.filter(c => this._matchFilter(c)); }
    get filteredSystemCategories() { return this.systemCategories.filter(c => this._matchFilter(c)); }
    get hasAppMatches()    { return this.filteredAppCategories.length > 0; }
    get hasSystemMatches() { return this.filteredSystemCategories.length > 0; }
    get noMatches()        { return !this.hasAppMatches && !this.hasSystemMatches; }
    handleFilterChange(event) { this.categoryFilter = event.target.value; }
    clearFilter()             { this.categoryFilter = ''; }

    // ── Deploy progress (Step 4) ─────────────────────────────────────────────────
    get deployPercent() {
        if (!this.totalComponents) return this.deployDone ? 100 : 0;
        return Math.round((this.deployedCount / this.totalComponents) * 100);
    }
    get deployVariant() {
        if (!this.deployDone) return 'base';
        return this.deploySuccess ? 'success' : 'error';
    }
    get isPartialSuccess() { return this.deployDone && this.deploySuccess && this.hasSkipped; }
    get skippedCount()     { return this.skippedItems ? this.skippedItems.length : 0; }

    // ── Step 1 — searchable Profile picker ──────────────────────────────────────
    get filteredProfileOptions() {
        const q = (this.profileSearch || '').toLowerCase().trim();
        const list = q
            ? this.profileOptions.filter(o => o.label.toLowerCase().includes(q))
            : this.profileOptions;
        return list.map(o => ({
            ...o,
            selected: o.value === this.selectedProfileId,
            rowClass: o.value === this.selectedProfileId ? 'picker-item is-selected' : 'picker-item'
        }));
    }
    get profileNoMatches() { return this.profileDropdownOpen && this.filteredProfileOptions.length === 0; }

    handleProfileSearch(event) {
        this.profileSearch = event.target.value;
        this.profileDropdownOpen = true;
        // Typing invalidates a prior pick until the user chooses again.
        this.selectedProfileId = null;
        this.selectedProfileLabel = '';
        this.profileSummary = null;
    }
    openProfileDropdown()  { this.profileDropdownOpen = true; }
    closeProfileDropdown() { this.profileDropdownOpen = false; }

    async selectProfile(event) {
        const val = event.currentTarget.dataset.value;
        const opt = this.profileOptions.find(o => o.value === val);
        this.selectedProfileId    = val;
        this.selectedProfileLabel = opt ? opt.label : val;
        this.profileSearch        = this.selectedProfileLabel;
        this.profileDropdownOpen  = false;
        this.profileSummary = null;
        try {
            this.profileSummary = await getProfileSummary({ profileId: this.selectedProfileId });
        } catch (e) { /* summary is informational */ }
    }

    goStep2() { if (this.selectedProfileId) this.currentStep = '2'; }

    // ── Step 2 — searchable Permission Set picker ───────────────────────────────
    get filteredPermSetOptions() {
        const q = (this.permSetSearch || '').toLowerCase().trim();
        const list = q
            ? this.permSetOptions.filter(o => o.label.toLowerCase().includes(q))
            : this.permSetOptions;
        return list.map(o => ({
            ...o,
            selected: o.value === this.selectedPermSet,
            rowClass: o.value === this.selectedPermSet ? 'picker-item is-selected' : 'picker-item'
        }));
    }
    get permSetNoMatches() { return this.permSetDropdownOpen && this.filteredPermSetOptions.length === 0; }

    handlePermSetSearch(event) {
        this.permSetSearch = event.target.value;
        this.permSetDropdownOpen = true;
        this.selectedPermSet = '';
        this.permSetLabel = '';
    }
    openPermSetDropdown()  { this.permSetDropdownOpen = true; }
    closePermSetDropdown() { this.permSetDropdownOpen = false; }

    selectPermSet(event) {
        const val = event.currentTarget.dataset.value;
        const opt = this.permSetOptions.find(o => o.value === val);
        this.selectedPermSet     = val;
        this.permSetLabel        = opt ? opt.label : val;
        this.permSetSearch       = this.permSetLabel;
        this.permSetDropdownOpen = false;
    }

    goStep1() { this.currentStep = '1'; }
    goStep3() { if (this.selectedPermSet) this.currentStep = '3'; }

    // ── Step 3 ────────────────────────────────────────────────────────────────
    handleCatChange(event) {
        const val     = event.target.dataset.value;
        const checked = event.detail.checked;
        this.appCategories    = this.appCategories.map(c    => c.value === val ? { ...c, checked } : c);
        this.systemCategories = this.systemCategories.map(c => c.value === val ? { ...c, checked } : c);
    }

    selectAll() {
        this.appCategories    = this.appCategories.map(c    => ({ ...c, checked: true }));
        this.systemCategories = this.systemCategories.map(c => ({ ...c, checked: true }));
    }
    clearAll() {
        this.appCategories    = this.appCategories.map(c    => ({ ...c, checked: false }));
        this.systemCategories = this.systemCategories.map(c => ({ ...c, checked: false }));
    }

    async handleMerge() {
        const cats = this.allCats.filter(c => c.checked).map(c => c.value);
        if (!cats.length) return;
        if (!this.sessionId) {
            this.toast('Please wait', 'Still acquiring the Metadata API session. Try again in a moment.', 'warning');
            return;
        }

        this.isMerging = true;
        try {
            const result = await mergePermissions({
                profileId:         this.selectedProfileId,
                permSetName:       this.selectedPermSet,
                categoriesToMerge: cats,
                sessionId:         this.sessionId
            });

            if (result.success) {
                this.deployJobId      = result.jobId;
                this.mergedCategories = result.merged || [];
                this.skippedItems     = result.skipped || [];
                this.deployDone       = false;
                this.deploySuccess    = false;
                this.deployState      = 'Pending';
                this.currentStep      = '4';
                this.startPolling();
            } else {
                this.toast('Error', result.message, 'error');
            }
        } catch (e) {
            this.toast('Error', this.errMsg(e), 'error');
        } finally {
            this.isMerging = false;
        }
    }

    // ── Polling ───────────────────────────────────────────────────────────────
    startPolling() {
        this._pollTimer = setInterval(() => this.pollStatus(), 4000);
    }

    async pollStatus() {
        if (!this.deployJobId) return;
        try {
            const s = await checkDeployStatus({ jobId: this.deployJobId, sessionId: this.sessionId });
            this.deployState     = s.state     || 'InProgress';
            this.deployedCount   = s.numberDeployed || 0;
            this.totalComponents = s.numberTotal    || 0;

            if (s.done) {
                this.deployDone    = true;
                this.deploySuccess = s.state === 'Succeeded';
                this.deployError   = s.errorMessage || '';
                clearInterval(this._pollTimer);
                this._pollTimer = null;
                this.toast(
                    this.deploySuccess ? 'Success' : 'Error',
                    this.deploySuccess
                        ? 'Permission set "' + this.selectedPermSet + '" updated successfully.'
                        : 'Deployment failed: ' + this.deployError,
                    this.deploySuccess ? 'success' : 'error'
                );
            }
        } catch (e) { console.error('Poll error:', e); }
    }

    // ── Reset ─────────────────────────────────────────────────────────────────
    resetWizard() {
        if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = null; }
        this.currentStep         = '1';
        this.selectedProfileId   = null;
        this.selectedProfileLabel= '';
        this.selectedPermSet     = '';
        this.profileSearch       = '';
        this.profileDropdownOpen = false;
        this.permSetSearch       = '';
        this.permSetLabel        = '';
        this.permSetDropdownOpen = false;
        this.profileSummary      = null;
        this.deployJobId         = null;
        this.deployDone          = false;
        this.deploySuccess       = false;
        this.deployError         = '';
        this.mergedCategories    = [];
        this.skippedItems        = [];
        this.deployState         = 'Pending';
        this.appCategories       = APP_CATEGORIES.map(c => ({ ...c }));
        this.systemCategories    = SYSTEM_CATEGORIES.map(c => ({ ...c }));
        this.categoryFilter      = '';
    }

    get hasSkipped() { return this.skippedItems && this.skippedItems.length > 0; }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    errMsg(e) {
        if (typeof e === 'string')  return e;
        if (e?.body?.message)       return e.body.message;
        if (e?.message)             return e.message;
        return JSON.stringify(e);
    }
}

# Profile to Permission Set Merger

A Salesforce Lightning Web Component (LWC) that merges all the permissions from a Profile into an existing Permission Set, additively and in place. Built for admins who are moving away from profile-based permissions and need to fold a profile's access into a permission set without rebuilding it by hand.

---

## Why This Exists

Salesforce has been steering orgs toward permission sets for years, and profiles are on the way out as the place to manage most permissions. But there is no native way to take everything a profile grants and move it onto a permission set. You are left re-creating object access, field access, Apex and Visualforce access, app assignments, system permissions, and more, one screen at a time, hoping you did not miss anything.

This tool does it in a few clicks. It reads the source profile, merges its permissions into the permission set you choose, and deploys the result. Nothing on the target is removed or downgraded; the merge only ever adds access.

---

## What It Does

Pick a source Profile and a target Permission Set, choose which categories to merge, and the tool builds and deploys the merged permission set for you. It covers:

**Object and Field Permissions**
Object CRUD (Read, Create, Edit, Delete, View All, Modify All) and field-level Read/Edit access. Field access is filtered to fields where field-level security can actually be set, so system fields that cannot carry FLS are skipped automatically instead of failing the deploy.

**Apex Class and Visualforce Page Access**
Execution access for Apex classes and Visualforce pages, including components from managed packages with their namespace preserved.

**Assigned Apps, Flows, and Custom Permissions**
Application visibility, Flow access, and custom permission assignments.

**Custom Metadata Types, Custom Settings, and External Data Sources**
Access to custom metadata type records, custom setting definitions, and external data source authentication.

**System Permissions**
The full set of user permissions the profile grants (for example Modify All Data, Manage Users), read directly from the profile so the names are always valid for deployment.

Selected permissions are merged as a union of source and target, so existing access on the permission set is preserved.

---

## How It Works

The component does most of the work through the Salesforce Metadata API rather than direct record updates, because the permission fields on a Permission Set are metadata and cannot be changed with normal DML.

- The source profile is read with the Metadata API `readMetadata` call. The access blocks it returns already carry correct, deployable names, which avoids the common problem of reconstructing names from IDs and getting managed-package or relationship names wrong.
- The merged permission set is packaged in memory and deployed with the Metadata API `deploy` call, then polled with `checkDeployStatus` until it finishes.
- A small number of permission types that have no Permission Set metadata element (for example Connected Apps, Named Credentials, and Service Presence Statuses) are applied as direct `SetupEntityAccess` records using partial-success DML, so a single unsupported entry does not stop the rest.
- A Metadata API session is supplied by a lightweight Visualforce page that passes the session to the component, because the standard Lightning session is not valid for the Metadata API.

---

## Getting Started

### Prerequisites

- Salesforce CLI (`sf`) installed
- A Salesforce org (Developer Edition, Sandbox, or Scratch Org)
- VS Code with the Salesforce Extension Pack (optional but recommended)
- A My Domain that is deployed and active (required for the Metadata API callout)

### Deploy via CLI

```bash
# Authenticate to your org
sf org login web --alias myOrg

# Deploy everything (Apex, LWC, Visualforce page, remote site setting)
sf project deploy start --source-dir force-app --target-org myOrg
```

### Deploy via VS Code

1. Open this project folder in VS Code
2. Press `Ctrl+Shift+P` then choose **SFDX: Authorize an Org**
3. Right-click the `force-app` folder
4. Click **Deploy Source to Org**

---

## Required Post-Deploy Configuration

The tool will not work until these two steps are done.

**1. Point the Remote Site Setting at your My Domain.**
The deploy includes a Remote Site Setting that must contain your org's My Domain URL. Go to **Setup then Remote Site Settings**, open the entry created by this package, and set the URL to your My Domain (for example `https://yourdomain.my.salesforce.com`). Without this the Metadata API callout is blocked.

**2. Confirm the Visualforce session page is accessible.**
The included Visualforce page supplies the Metadata API session to the component. Make sure the running user's profile or permission set has access to it.

---

## Adding It to a Page

1. Go to **Setup then Lightning App Builder**
2. Open or create a Home Page, App Page, or Record Page
3. Find **profileToPermSetMerger** under Custom Components in the left panel
4. Drag it onto the page
5. Save and Activate

---

## How to Use It

**Step 1 - Select Profile.** Type to filter the list of profiles and click the one you want to merge from. A summary of the profile loads underneath.

**Step 2 - Select Permission Set.** Type to filter and click the target permission set the permissions will be merged into.

**Step 3 - Choose Categories.** Every category is selected by default. Use the filter box to find a specific one, or use Select All and Clear All. Uncheck anything you do not want to merge, then click Merge and Deploy.

**Step 4 - Deploy.** A progress bar shows how many components have deployed. When it finishes you get a summary of what merged, and any individual access rows the org rejected are listed separately so you know exactly what was and was not applied.

---

## Project Structure

```
force-app/main/default/
├── classes/
│   ├── PermSetMergerController.cls
│   ├── PermSetMergerController.cls-meta.xml
│   ├── PermSetMergerControllerTest.cls
│   ├── PermSetMergerControllerTest.cls-meta.xml
│   ├── Zippex.cls
│   └── Zippex.cls-meta.xml
├── lwc/
│   └── profileToPermSetMerger/
│       ├── profileToPermSetMerger.html
│       ├── profileToPermSetMerger.js
│       ├── profileToPermSetMerger.css
│       └── profileToPermSetMerger.js-meta.xml
├── pages/
│   ├── PermSetMergerSession.page
│   └── PermSetMergerSession.page-meta.xml
└── remoteSiteSettings/
    └── SalesforceMetadataAPI.remoteSiteSetting-meta.xml
```

---

## Permissions Required

The user running the component needs:

- **Customize Application** and **Modify Metadata Through Metadata API Functions**, so the Metadata API deploy can run
- **Manage Profiles and Permission Sets**, to read the source profile and update the target permission set
- Access to the `PermSetMergerController` Apex class and the `PermSetMergerSession` Visualforce page

Grant these through a permission set assigned to the admins who will use the tool.

---

## Technical Notes

- **Source permissions** are read from the profile with the Metadata API `readMetadata` call, so access names are always in their deployable form, including namespace prefixes for managed components.
- **Field permissions** are filtered with `Schema.DescribeFieldResult.isPermissionable()`, which is the same condition the deploy enforces, so fields that cannot carry FLS are dropped before deployment rather than causing a failure.
- **Deployment** uses the Metadata API `deploy` and `checkDeployStatus` SOAP calls. The permission set file is zipped in pure Apex with the bundled `Zippex` class.
- **Unsupported types** that have no Permission Set metadata element are written directly as `SetupEntityAccess` records using partial-success DML, and any skipped rows are reported back in the UI.
- **Session handling** is done through a Visualforce page because the standard Lightning session ID cannot authenticate Metadata API calls.

---

## Known Limitations

- The Remote Site Setting URL must be set to your My Domain after deployment, or the Metadata API callout will be blocked.
- The whole source profile is read into memory in a single synchronous call. This is fine for normal business profiles, but a very large profile (for example a System Administrator profile with field-level security on tens of thousands of fields) can approach Apex heap or CPU limits. If that happens the build should be moved to an asynchronous (Queueable) process.
- A few legacy or special permissions cannot be deployed through the Permission Set metadata element and may need to be set manually.
- Standard profiles whose names do not resolve through the Metadata API may not merge; custom profiles are the primary supported case.
- The `SetupEntityAccess` records and System Permissions are committed during the run and are not rolled back if a later step of the deploy fails.
- The merge is additive only. It adds the access the profile grants and does not remove or downgrade anything already on the target permission set.

---

## Contributing

Bug reports and ideas are welcome.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/your-idea`)
3. Make your changes
4. Push and open a Pull Request

---

## License

MIT. Use it, modify it, share it.

---

Built to make the move from profiles to permission sets less painful.

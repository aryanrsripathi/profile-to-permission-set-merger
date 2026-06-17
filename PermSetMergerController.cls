/**
 * @description Profile → Permission Set Merger
 *
 *  READ:   Pure SOQL from profile-backed PermissionSet
 *  DEPLOY: SOAP Metadata API deploy (avoids REST ZIP parsing issues)
 *
 *  The SOAP deploy wraps the ZIP in base64 inside XML — same session,
 *  same org, no external callout configuration needed beyond the
 *  Remote Site Setting pointing to your org domain.
 */
public without sharing class PermSetMergerController {

    private static final String API_VER = '59.0';
    private static final String META_NS = 'http://soap.sforce.com/2006/04/metadata';

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        public PicklistOption(String lbl, String val) {
            this.label = lbl; this.value = val;
        }
    }

    public class MergeResult {
        @AuraEnabled public Boolean      success { get; set; }
        @AuraEnabled public String       message { get; set; }
        @AuraEnabled public String       jobId   { get; set; }
        @AuraEnabled public List<String> merged  { get; set; }
        @AuraEnabled public List<String> skipped { get; set; }
        public MergeResult(Boolean s, String m, String j, List<String> mg, List<String> sk) {
            success = s; message = m; jobId = j;
            merged  = mg != null ? mg : new List<String>();
            skipped = sk != null ? sk : new List<String>();
        }
    }

    public class DeployStatus {
        @AuraEnabled public String  state          { get; set; }
        @AuraEnabled public Boolean done           { get; set; }
        @AuraEnabled public String  errorMessage   { get; set; }
        @AuraEnabled public Integer numberDeployed { get; set; }
        @AuraEnabled public Integer numberTotal    { get; set; }
    }

    public class PermSummary {
        @AuraEnabled public Integer objectPerms { get; set; }
        @AuraEnabled public Integer fieldPerms  { get; set; }
        @AuraEnabled public Integer apexClasses { get; set; }
        @AuraEnabled public Integer vfPages     { get; set; }
        @AuraEnabled public Integer flows       { get; set; }
        @AuraEnabled public Integer customPerms { get; set; }
        @AuraEnabled public Integer tabSettings { get; set; }
    }

    // ─── Picklists ────────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getProfiles() {
        List<PicklistOption> opts = new List<PicklistOption>();
        for (Profile p : [SELECT Id, Name FROM Profile ORDER BY Name LIMIT 200])
            opts.add(new PicklistOption(p.Name, p.Id));
        return opts;
    }

    @AuraEnabled(cacheable=true)
    public static List<PicklistOption> getPermissionSets() {
        List<PicklistOption> opts = new List<PicklistOption>();
        for (PermissionSet ps : [
            SELECT Id, Label, Name FROM PermissionSet
            WHERE IsOwnedByProfile = false ORDER BY Label LIMIT 500
        ]) {
            opts.add(new PicklistOption(ps.Label + ' (' + ps.Name + ')', ps.Name));
        }
        return opts;
    }

    @AuraEnabled(cacheable=true)
    public static PermSummary getProfileSummary(Id profileId) {
        List<PermissionSet> psList = [
            SELECT Id FROM PermissionSet
            WHERE ProfileId = :profileId AND IsOwnedByProfile = true LIMIT 1
        ];
        if (psList.isEmpty()) return new PermSummary();
        Id psId = psList[0].Id;

        PermSummary s = new PermSummary();
        s.objectPerms = [SELECT COUNT() FROM ObjectPermissions       WHERE ParentId = :psId];
        s.fieldPerms  = [SELECT COUNT() FROM FieldPermissions        WHERE ParentId = :psId];
        s.apexClasses = [SELECT COUNT() FROM SetupEntityAccess       WHERE ParentId = :psId AND SetupEntityType = 'ApexClass'];
        s.vfPages     = [SELECT COUNT() FROM SetupEntityAccess       WHERE ParentId = :psId AND SetupEntityType = 'ApexPage'];
        s.flows       = [SELECT COUNT() FROM SetupEntityAccess       WHERE ParentId = :psId AND SetupEntityType = 'Flow'];
        s.customPerms = [SELECT COUNT() FROM SetupEntityAccess       WHERE ParentId = :psId AND SetupEntityType = 'CustomPermission'];
        s.tabSettings = [SELECT COUNT() FROM PermissionSetTabSetting WHERE ParentId = :psId];
        return s;
    }

    @AuraEnabled
    public static String getSessionId() {
        return UserInfo.getSessionId();
    }

    // ─── Main merge ───────────────────────────────────────────────────────────

    @AuraEnabled
    public static MergeResult mergePermissions(
        Id           profileId,
        String       permSetName,
        List<String> categoriesToMerge,
        String       sessionId
    ) {
        try {
            if (String.isBlank(sessionId)) {
                return new MergeResult(false,
                    'No Metadata API session available yet. Wait a moment for the session loader to finish, then try again.',
                    null, null, null);
            }
            // Find the profile-backed PermissionSet (source of all permissions)
            List<PermissionSet> srcList = [
                SELECT Id FROM PermissionSet
                WHERE ProfileId = :profileId AND IsOwnedByProfile = true LIMIT 1
            ];
            if (srcList.isEmpty()) {
                return new MergeResult(false,
                    'Could not find the profile-backed PermissionSet. Ensure the Profile Id is valid.',
                    null, null, null);
            }
            Id srcPsId = srcList[0].Id;

            // Find target PermissionSet (may be null if brand new)
            List<PermissionSet> tgtList = [
                SELECT Id FROM PermissionSet
                WHERE Name = :permSetName AND IsOwnedByProfile = false LIMIT 1
            ];
            Id tgtPsId = tgtList.isEmpty() ? null : tgtList[0].Id;

            Set<String> cats = new Set<String>(categoriesToMerge);

            // Profile metadata fullName (for readMetadata of system permissions)
            String profileName = '';
            for (Profile p : [SELECT Name FROM Profile WHERE Id = :profileId LIMIT 1])
                profileName = p.Name;

            // Build merged permission set XML from SOQL data
            String psXml = buildPermSetXml(srcPsId, tgtPsId, permSetName, cats, profileName, sessionId);

            // Build the deploy ZIP using Zippex
            String packageXml =
                '<?xml version="1.0" encoding="UTF-8"?>\n'
              + '<Package xmlns="' + META_NS + '">\n'
              + '  <types>\n'
              + '    <members>' + permSetName + '</members>\n'
              + '    <name>PermissionSet</name>\n'
              + '  </types>\n'
              + '  <version>' + API_VER + '</version>\n'
              + '</Package>';

            Zippex zf = new Zippex();
            zf.addFile('package.xml', Blob.valueOf(packageXml), null);
            zf.addFile('permissionsets/' + permSetName + '.permissionset-meta.xml',
                       Blob.valueOf(psXml), null);
            String zipBase64 = EncodingUtil.base64Encode(zf.getZipArchive());

            // Deploy via SOAP Metadata API — more reliable than REST for binary ZIP.
            // IMPORTANT: the callout MUST happen before any DML, otherwise Apex
            // throws "You have uncommitted work pending. Please commit or rollback
            // before calling out." So the SetupEntityAccess grants run AFTER this.
            String jobId = soapDeploy(zipBase64, sessionId);

            // ── SetupEntityAccess-only grants (AFTER the callout) ───────────────
            // ConnectedApplication, NamedCredential and ServicePresenceStatus have
            // NO PermissionSet metadata element, so they cannot go in the deploy
            // XML. For permission sets these are grantable by direct DML on
            // SetupEntityAccess (additively). Requires the target permission set to
            // already exist (it does — the user picks it).
            // Use allOrNone=false so one rejected reference (INVALID_CROSS_REFERENCE_KEY)
            // can't abort the whole merge — skipped rows are reported back with the
            // entity type and the actual Salesforce error so the cause is visible.
            List<String> skipped = new List<String>();
            if (tgtPsId != null) {
                List<SetupEntityAccess> grants = new List<SetupEntityAccess>();
                List<String>            types  = new List<String>();  // parallel to grants
                if (cats.contains('assignedConnectedApps') || cats.contains('serviceProviderAccess'))
                    addGrants(grants, types, buildSetupAccess(srcPsId, tgtPsId, 'ConnectedApplication'), 'ConnectedApplication');
                if (cats.contains('namedCredentialAccess'))
                    addGrants(grants, types, buildSetupAccess(srcPsId, tgtPsId, 'NamedCredential'), 'NamedCredential');
                if (cats.contains('servicePresenceStatusAccess'))
                    addGrants(grants, types, buildSetupAccess(srcPsId, tgtPsId, 'ServicePresenceStatus'), 'ServicePresenceStatus');
                if (!grants.isEmpty()) {
                    Database.SaveResult[] srs = Database.insert(grants, false);
                    for (Integer i = 0; i < srs.size(); i++) {
                        if (!srs[i].isSuccess()) {
                            String err = srs[i].getErrors().isEmpty()
                                ? 'unknown error'
                                : srs[i].getErrors()[0].getStatusCode() + ': ' + srs[i].getErrors()[0].getMessage();
                            skipped.add(types[i] + ' (' + grants[i].SetupEntityId + ') — ' + err);
                        }
                    }
                }
            }

            return new MergeResult(true,
                'Deployment started. Job ID: ' + jobId,
                jobId, buildCatLabels(cats), skipped);

        } catch (Exception ex) {
            return new MergeResult(false, ex.getMessage(), null, null, null);
        }
    }

    @AuraEnabled
    public static DeployStatus checkDeployStatus(String jobId, String sessionId) {
        // Poll via SOAP checkDeployStatus
        String soapBody =
            '<?xml version="1.0" encoding="utf-8"?>'
          + '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">'
          + '<env:Header><CallOptions xmlns="' + META_NS + '"><client>PermMerger</client></CallOptions>'
          + '<SessionHeader xmlns="' + META_NS + '"><sessionId>' + xmlEsc(sessionId) + '</sessionId></SessionHeader>'
          + '</env:Header>'
          + '<env:Body>'
          + '<checkDeployStatus xmlns="' + META_NS + '">'
          + '<asyncProcessId>' + jobId + '</asyncProcessId>'
          + '<includeDetails>true</includeDetails>'
          + '</checkDeployStatus>'
          + '</env:Body></env:Envelope>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + API_VER);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(30000);
        req.setBody(soapBody);

        HttpResponse  res = new Http().send(req);
        DeployStatus  ds  = new DeployStatus();
        String        body = res.getBody();

        ds.done           = body.contains('<done>true</done>');
        ds.state          = extractTag(body, 'status');
        ds.numberDeployed = intFromTag(body, 'numberComponentsDeployed');
        ds.numberTotal    = intFromTag(body, 'numberComponentsTotal');

        if (ds.done == true && ds.state != 'Succeeded') {
            // Extract first problem message
            String prob = extractTag(body, 'problem');
            ds.errorMessage = String.isNotBlank(prob) ? prob : extractTag(body, 'errorMessage');
        }
        return ds;
    }

    // ─── XML builder ─────────────────────────────────────────────────────────

    private static String buildPermSetXml(Id srcId, Id tgtId, String psName, Set<String> cats,
                                          String profileName, String sessionId) {
        // Get the label from the existing target perm set, or derive from name
        String label = psName.replace('_', ' ');
        if (tgtId != null) {
            List<PermissionSet> tgtPs = [SELECT Label FROM PermissionSet WHERE Id = :tgtId LIMIT 1];
            if (!tgtPs.isEmpty() && String.isNotBlank(tgtPs[0].Label)) label = tgtPs[0].Label;
        }

        // Collect each element's content keyed by its element name. The
        // PermissionSet type is an xsd:sequence, so the elements MUST be emitted
        // in alphabetical order by element name (see `ELEMENT_ORDER`).
        // NOTE: ConnectedApplication, NamedCredential and ServicePresenceStatus
        // are NOT valid PermissionSet elements — they are granted via
        // SetupEntityAccess DML in mergePermissions(), not here.
        Map<String, String> parts = new Map<String, String>();
        parts.put('hasActivationRequired', '  <hasActivationRequired>false</hasActivationRequired>\n');
        parts.put('label', '  <label>' + xmlEsc(label) + '</label>\n');

        if (cats.contains('objectSettings')) {
            parts.put('objectPermissions', objectPermsXml(srcId, tgtId));
            parts.put('fieldPermissions',  fieldPermsXml(srcId, tgtId));
        }

        // Everything below is read from the source PROFILE's metadata (one
        // readMetadata callout), then copied verbatim. This gives correct,
        // deployable names with no fragile SetupEntityId→Id joins — the same
        // mechanism that already works for System Permissions. Blocks that are
        // structurally identical between Profile and PermissionSet copy as-is;
        // applicationVisibilities needs its Profile-only <default> child stripped.
        Boolean needProfile =
            cats.contains('apexClassAccess') || cats.contains('visualforcePageAccess') ||
            cats.contains('assignedApps')    || cats.contains('appPermissions')        ||
            cats.contains('flowAccess')      || cats.contains('externalDataSourceAccess') ||
            cats.contains('customPermissions') || cats.contains('customMetadataTypes')  ||
            cats.contains('customSettingDefinitions') || cats.contains('systemPermissions');
        String profileXml = needProfile ? fetchProfileMetadata(profileName, sessionId) : '';

        if (cats.contains('apexClassAccess'))
            parts.put('classAccesses', extractBlocks(profileXml, 'classAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('visualforcePageAccess'))
            parts.put('pageAccesses', extractBlocks(profileXml, 'pageAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('assignedApps') || cats.contains('appPermissions'))
            parts.put('applicationVisibilities', extractBlocks(profileXml, 'applicationVisibilities', '<visible>true</visible>', true));
        if (cats.contains('flowAccess'))
            parts.put('flowAccesses', extractBlocks(profileXml, 'flowAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('externalDataSourceAccess'))
            parts.put('externalDataSourceAccesses', extractBlocks(profileXml, 'externalDataSourceAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('customPermissions'))
            parts.put('customPermissions', extractBlocks(profileXml, 'customPermissions', '<enabled>true</enabled>', false));
        if (cats.contains('customMetadataTypes'))
            parts.put('customMetadataTypeAccesses', extractBlocks(profileXml, 'customMetadataTypeAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('customSettingDefinitions'))
            parts.put('customSettingAccesses', extractBlocks(profileXml, 'customSettingAccesses', '<enabled>true</enabled>', false));
        if (cats.contains('tabSettings'))
            parts.put('tabSettings', tabSettingsXml(srcId, tgtId));
        if (cats.contains('systemPermissions'))
            parts.put('userPermissions', extractBlocks(profileXml, 'userPermissions', '<enabled>true</enabled>', false));

        List<String> out = new List<String>();
        out.add('<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="' + META_NS + '">\n');
        for (String el : ELEMENT_ORDER) {
            String content = parts.get(el);
            if (String.isNotBlank(content)) out.add(content);
        }
        out.add('</PermissionSet>');
        return String.join(out, '');
    }

    // Alphabetical element sequence required by the PermissionSet XSD.
    private static final List<String> ELEMENT_ORDER = new List<String>{
        'applicationVisibilities',
        'classAccesses',
        'customMetadataTypeAccesses',
        'customPermissions',
        'customSettingAccesses',
        'externalDataSourceAccesses',
        'fieldPermissions',
        'flowAccesses',
        'hasActivationRequired',
        'label',
        'objectPermissions',
        'pageAccesses',
        'tabSettings',
        'userPermissions'
    };



    // ── Object permissions ────────────────────────────────────────────────────

    private static String objectPermsXml(Id srcId, Id tgtId) {
        Map<String, ObjectPermissions> tgt = new Map<String, ObjectPermissions>();
        if (tgtId != null) {
            for (ObjectPermissions op : [
                SELECT SobjectType, PermissionsRead, PermissionsCreate, PermissionsEdit,
                       PermissionsDelete, PermissionsViewAllRecords, PermissionsModifyAllRecords
                FROM ObjectPermissions WHERE ParentId = :tgtId
            ]) { tgt.put(op.SobjectType, op); }
        }
        List<String> parts = new List<String>();
        for (ObjectPermissions s : [
            SELECT SobjectType, PermissionsRead, PermissionsCreate, PermissionsEdit,
                   PermissionsDelete, PermissionsViewAllRecords, PermissionsModifyAllRecords
            FROM ObjectPermissions WHERE ParentId = :srcId
        ]) {
            ObjectPermissions t = tgt.get(s.SobjectType);
            parts.add('  <objectPermissions>\n'
                 + '    <allowCreate>'      + b(s.PermissionsCreate           || (t!=null&&t.PermissionsCreate))           + '</allowCreate>\n'
                 + '    <allowDelete>'      + b(s.PermissionsDelete           || (t!=null&&t.PermissionsDelete))           + '</allowDelete>\n'
                 + '    <allowEdit>'        + b(s.PermissionsEdit             || (t!=null&&t.PermissionsEdit))             + '</allowEdit>\n'
                 + '    <allowRead>'        + b(s.PermissionsRead             || (t!=null&&t.PermissionsRead))             + '</allowRead>\n'
                 + '    <modifyAllRecords>' + b(s.PermissionsModifyAllRecords || (t!=null&&t.PermissionsModifyAllRecords)) + '</modifyAllRecords>\n'
                 + '    <object>'           + xmlEsc(s.SobjectType)                                                        + '</object>\n'
                 + '    <viewAllRecords>'   + b(s.PermissionsViewAllRecords   || (t!=null&&t.PermissionsViewAllRecords))   + '</viewAllRecords>\n'
                 + '  </objectPermissions>\n');
        }
        return String.join(parts, '');
    }

    // ── Field permissions ─────────────────────────────────────────────────────

    private static String fieldPermsXml(Id srcId, Id tgtId) {
        Map<String, FieldPermissions> tgt = new Map<String, FieldPermissions>();
        if (tgtId != null) {
            for (FieldPermissions fp : [
                SELECT Field, PermissionsRead, PermissionsEdit
                FROM FieldPermissions WHERE ParentId = :tgtId
            ]) { tgt.put(fp.Field, fp); }
        }
        List<FieldPermissions> srcPerms = [
            SELECT Field, PermissionsRead, PermissionsEdit
            FROM FieldPermissions WHERE ParentId = :srcId
        ];

        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        Map<String, Map<String, Schema.SObjectField>> objFieldCache =
            new Map<String, Map<String, Schema.SObjectField>>();

        List<String> parts = new List<String>();
        for (FieldPermissions s : srcPerms) {
            // Field looks like "Object.FieldApiName". Only emit it if FLS can
            // actually be set on the field — isPermissionable() is exactly the
            // deploy's requirement, so this drops system fields like
            // Location.LocationId that otherwise fail with "no CustomField found".
            String objName = s.Field.substringBefore('.');
            String fldName = s.Field.substringAfter('.');
            if (String.isBlank(objName) || String.isBlank(fldName)) continue;

            Map<String, Schema.SObjectField> fmap = objFieldCache.get(objName.toLowerCase());
            if (fmap == null) {
                Schema.SObjectType sot = gd.get(objName.toLowerCase());
                if (sot == null) continue;            // object not describable → skip
                fmap = sot.getDescribe().fields.getMap();
                objFieldCache.put(objName.toLowerCase(), fmap);
            }
            Schema.SObjectField sf = fmap.get(fldName.toLowerCase());
            if (sf == null) continue;                  // field not found → skip
            if (!sf.getDescribe().isPermissionable()) continue;  // FLS not settable → skip

            FieldPermissions t = tgt.get(s.Field);
            parts.add('  <fieldPermissions>\n'
                 + '    <editable>' + b(s.PermissionsEdit || (t!=null&&t.PermissionsEdit)) + '</editable>\n'
                 + '    <field>'    + xmlEsc(s.Field)                                      + '</field>\n'
                 + '    <readable>' + b(s.PermissionsRead || (t!=null&&t.PermissionsRead)) + '</readable>\n'
                 + '  </fieldPermissions>\n');
        }
        return String.join(parts, '');
    }

    // ── SetupEntityAccess ─────────────────────────────────────────────────────

    private static String setupEntityXml(Id srcId, Id tgtId, String entityType,
                                         String xmlElem, String xmlKey, String boolTag) {
        Set<Id> tgtIds = new Set<Id>();
        if (tgtId != null) {
            for (SetupEntityAccess s : [
                SELECT SetupEntityId FROM SetupEntityAccess
                WHERE ParentId = :tgtId AND SetupEntityType = :entityType
            ]) { tgtIds.add(s.SetupEntityId); }
        }
        Set<Id> allIds = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId FROM SetupEntityAccess
            WHERE ParentId = :srcId AND SetupEntityType = :entityType
        ]) { allIds.add(s.SetupEntityId); }
        allIds.addAll(tgtIds);
        if (allIds.isEmpty()) return '';

        // Children must be in alphabetical order within the element, e.g.
        // <apexClass> before <enabled>, <application> before <visible>.
        Boolean keyFirst = xmlKey.compareTo(boolTag) < 0;
        Map<Id, String> names = entityNames(entityType, allIds);
        List<String> parts = new List<String>();
        for (Id eid : allIds) {
            String n = names.get(eid);
            if (n == null) continue;
            String keyLine  = '    <' + xmlKey + '>' + xmlEsc(n) + '</' + xmlKey + '>\n';
            String boolLine = '    <' + boolTag + '>true</' + boolTag + '>\n';
            parts.add('  <' + xmlElem + '>\n'
                 + (keyFirst ? keyLine + boolLine : boolLine + keyLine)
                 + '  </' + xmlElem + '>\n');
        }
        return String.join(parts, '');
    }

    // Append rows to `grants` while recording each row's entity type in the
    // parallel `types` list, so a failed insert can be reported with its type.
    private static void addGrants(List<SetupEntityAccess> grants, List<String> types,
                                  List<SetupEntityAccess> rows, String entityType) {
        for (SetupEntityAccess r : rows) { grants.add(r); types.add(entityType); }
    }

    // ── SetupEntityAccess DML (for access types with no PermissionSet element) ──
    // ConnectedApplication, NamedCredential, ServicePresenceStatus can't go in the
    // deploy XML, but their access IS grantable to a permission set by inserting
    // SetupEntityAccess rows directly. Returns only the rows missing on the target.
    private static List<SetupEntityAccess> buildSetupAccess(Id srcId, Id tgtId, String entityType) {
        Set<Id> existing = new Set<Id>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId FROM SetupEntityAccess
            WHERE ParentId = :tgtId AND SetupEntityType = :entityType
        ]) { existing.add(s.SetupEntityId); }

        List<SetupEntityAccess> toAdd = new List<SetupEntityAccess>();
        for (SetupEntityAccess s : [
            SELECT SetupEntityId FROM SetupEntityAccess
            WHERE ParentId = :srcId AND SetupEntityType = :entityType
        ]) {
            if (!existing.contains(s.SetupEntityId)) {
                toAdd.add(new SetupEntityAccess(
                    ParentId = tgtId, SetupEntityId = s.SetupEntityId));
            }
        }
        return toAdd;
    }


    // Prepend the managed-package namespace (e.g. 'scc__') when present, so the
    // metadata reference matches the deployable fully-qualified name. Without this,
    // managed components fail with "no <Type> named <Name> found".
    private static String withNs(String nsPrefix, String baseName) {
        if (String.isBlank(baseName) || String.isBlank(nsPrefix)) return baseName;
        String pfx = nsPrefix + '__';
        return baseName.startsWith(pfx) ? baseName : pfx + baseName;
    }

    private static Map<Id, String> entityNames(String type, Set<Id> ids) {
        Map<Id, String> m = new Map<Id, String>();
        if (ids.isEmpty()) return m;
        try {
            if (type == 'ApexClass') {
                for (ApexClass r : [SELECT Id, Name, NamespacePrefix FROM ApexClass WHERE Id IN :ids])
                    m.put(r.Id, withNs(r.NamespacePrefix, r.Name));
            } else if (type == 'ApexPage') {
                for (ApexPage r : [SELECT Id, Name, NamespacePrefix FROM ApexPage WHERE Id IN :ids])
                    m.put(r.Id, withNs(r.NamespacePrefix, r.Name));
            } else if (type == 'Flow') {
                for (FlowDefinitionView r : [SELECT Id, ApiName FROM FlowDefinitionView WHERE Id IN :ids])
                    m.put(r.Id, r.ApiName);
            } else if (type == 'CustomPermission') {
                for (CustomPermission r : [SELECT Id, DeveloperName, NamespacePrefix FROM CustomPermission WHERE Id IN :ids])
                    m.put(r.Id, withNs(r.NamespacePrefix, r.DeveloperName));
            } else if (type == 'ConnectedApplication') {
                for (ConnectedApplication r : [SELECT Id, Name FROM ConnectedApplication WHERE Id IN :ids])
                    m.put(r.Id, r.Name);
            } else if (type == 'ExternalDataSource') {
                for (ExternalDataSource r : [SELECT Id, DeveloperName, NamespacePrefix FROM ExternalDataSource WHERE Id IN :ids])
                    m.put(r.Id, withNs(r.NamespacePrefix, r.DeveloperName));
            } else if (type == 'NamedCredential') {
                for (NamedCredential r : [SELECT Id, DeveloperName FROM NamedCredential WHERE Id IN :ids])
                    m.put(r.Id, r.DeveloperName);
            } else if (type == 'TabSet') {
                for (AppDefinition r : [SELECT Id, DeveloperName FROM AppDefinition WHERE Id IN :ids])
                    m.put(r.Id, r.DeveloperName);
            } else if (type == 'CustomMetadataType' || type == 'CustomSetting') {
                for (EntityDefinition r : [SELECT Id, QualifiedApiName FROM EntityDefinition WHERE Id IN :ids])
                    m.put(r.Id, r.QualifiedApiName);
            } else if (type == 'ServicePresenceStatus') {
                for (ServicePresenceStatus r : [SELECT Id, DeveloperName FROM ServicePresenceStatus WHERE Id IN :ids])
                    m.put(r.Id, r.DeveloperName);
            }
        } catch (Exception e) { /* SObject may not exist in org */ }
        return m;
    }

    // ── Tab settings ──────────────────────────────────────────────────────────

    private static String tabSettingsXml(Id srcId, Id tgtId) {
        Map<String, String> vis = new Map<String, String>();
        if (tgtId != null) {
            for (PermissionSetTabSetting ts : [
                SELECT Name, Visibility FROM PermissionSetTabSetting WHERE ParentId = :tgtId
            ]) { vis.put(ts.Name, ts.Visibility); }
        }
        for (PermissionSetTabSetting ts : [
            SELECT Name, Visibility FROM PermissionSetTabSetting WHERE ParentId = :srcId
        ]) {
            String cur = vis.get(ts.Name);
            if (cur == null || visRank(ts.Visibility) > visRank(cur))
                vis.put(ts.Name, ts.Visibility);
        }
        List<String> parts = new List<String>();
        for (String tab : vis.keySet()) {
            String v = vis.get(tab);
            String xmlV = v == 'Visible' ? 'DefaultOn' : v == 'Available' ? 'DefaultOff' : 'Hidden';
            // PermissionSet uses <tabSettings>; children <tab> then <visibility>.
            parts.add('  <tabSettings>\n'
                 + '    <tab>'        + xmlEsc(tab) + '</tab>\n'
                 + '    <visibility>' + xmlV         + '</visibility>\n'
                 + '  </tabSettings>\n');
        }
        return String.join(parts, '');
    }

    // ── System permissions via Metadata API readMetadata ───────────────────────
    // We do NOT derive permission names from PermissionSet field API names — many
    // Permissions* fields (EmailSingle, EditTask, ...) have no valid Metadata API
    // name and break the deploy with "Unknown user permission". Instead we read the
    // source Profile's metadata, which returns userPermissions with their CORRECT,
    // guaranteed-valid names, and emit exactly those. readMetadata is synchronous.
    // If it returns nothing (e.g. an unresolvable standard-profile fullName), system
    // permissions are simply not merged — no error.
    // Reads the source Profile's metadata via the Metadata API readMetadata call
    // and returns the raw SOAP response body (or '' on failure). The body holds
    // every access block (classAccesses, applicationVisibilities, flowAccesses,
    // userPermissions, …) with correct, deployable names already resolved by
    // Salesforce — which is why we copy from here instead of reconstructing names
    // from SetupEntityId joins.
    private static String fetchProfileMetadata(String profileName, String sessionId) {
        if (String.isBlank(profileName) || String.isBlank(sessionId)) return '';

        String body =
            '<?xml version="1.0" encoding="utf-8"?>'
          + '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">'
          + '<env:Header>'
          + '<CallOptions xmlns="' + META_NS + '"><client>PermMerger</client></CallOptions>'
          + '<SessionHeader xmlns="' + META_NS + '"><sessionId>' + xmlEsc(sessionId) + '</sessionId></SessionHeader>'
          + '</env:Header><env:Body>'
          + '<readMetadata xmlns="' + META_NS + '">'
          + '<type>Profile</type><fullNames>' + xmlEsc(profileName) + '</fullNames>'
          + '</readMetadata>'
          + '</env:Body></env:Envelope>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + API_VER);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse res = new Http().send(req);
        return res.getStatusCode() == 200 ? res.getBody() : '';
    }

    // Pulls every <element>…</element> block out of a profile metadata response and
    // re-emits it for the permission set. Profile and PermissionSet share identical
    // child structure for these access types, so the inner XML copies verbatim.
    //  • trueMarker  — only blocks containing this marker are kept (skips the
    //                  enabled=false / visible=false entries), so the merge stays additive.
    //  • stripDefault — removes the Profile-only <default> child that PermissionSet
    //                  rejects (needed for applicationVisibilities).
    private static String extractBlocks(String resp, String element, String trueMarker, Boolean stripDefault) {
        if (String.isBlank(resp)) return '';
        String open  = '<' + element + '>';
        String close = '</' + element + '>';
        List<String> parts = new List<String>();
        Integer idx = 0;
        while (true) {
            Integer s = resp.indexOf(open, idx);
            if (s == -1) break;
            Integer e = resp.indexOf(close, s);
            if (e == -1) break;
            String inner = resp.substring(s + open.length(), e);
            idx = e + close.length();
            if (String.isNotBlank(trueMarker) && !inner.contains(trueMarker)) continue;
            if (stripDefault) inner = inner.replaceAll('<default>[^<]*</default>', '');
            parts.add('  ' + open + inner + close + '\n');
        }
        return String.join(parts, '');
    }


    // ─── SOAP Deploy ──────────────────────────────────────────────────────────

    private static String soapDeploy(String zipBase64, String sessionId) {
        String body =
            '<?xml version="1.0" encoding="utf-8"?>'
          + '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">'
          + '<env:Header>'
          + '<CallOptions xmlns="' + META_NS + '"><client>PermMerger</client></CallOptions>'
          + '<SessionHeader xmlns="' + META_NS + '"><sessionId>'
          + xmlEsc(sessionId) + '</sessionId></SessionHeader>'
          + '</env:Header>'
          + '<env:Body>'
          + '<deploy xmlns="' + META_NS + '">'
          + '<ZipFile>' + zipBase64 + '</ZipFile>'
          + '<DeployOptions>'
          + '<allowMissingFiles>false</allowMissingFiles>'
          + '<autoUpdatePackage>false</autoUpdatePackage>'
          + '<checkOnly>false</checkOnly>'
          + '<ignoreWarnings>true</ignoreWarnings>'
          + '<performRetrieve>false</performRetrieve>'
          + '<purgeOnDelete>false</purgeOnDelete>'
          + '<rollbackOnError>true</rollbackOnError>'
          + '<runAllTests>false</runAllTests>'
          + '<singlePackage>true</singlePackage>'
          + '<testLevel>NoTestRun</testLevel>'
          + '</DeployOptions>'
          + '</deploy>'
          + '</env:Body></env:Envelope>';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(URL.getOrgDomainUrl().toExternalForm() + '/services/Soap/m/' + API_VER);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse res = new Http().send(req);
        String resBody = res.getBody();

        if (res.getStatusCode() == 200) {
            String jobId = extractTag(resBody, 'id');
            if (String.isNotBlank(jobId)) return jobId;
        }
        // Parse SOAP fault if present
        String fault = extractTag(resBody, 'faultstring');
        throw new AuraHandledException(
            'SOAP deploy failed: ' + (String.isNotBlank(fault) ? fault : resBody.left(300)));
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static String extractTag(String xml, String tag) {
        if (xml == null) return '';
        // Tolerate namespace prefixes, e.g. <ns:id>...</ns:id> as well as <id>...</id>
        Pattern p = Pattern.compile('(?s)<(?:\\w+:)?' + Pattern.quote(tag) + '\\b[^>]*>(.*?)</(?:\\w+:)?' + Pattern.quote(tag) + '>');
        Matcher m = p.matcher(xml);
        if (m.find()) return m.group(1);
        return '';
    }

    private static Integer intFromTag(String xml, String tag) {
        String val = extractTag(xml, tag);
        if (String.isBlank(val)) return 0;
        try { return Integer.valueOf(val); } catch (Exception e) { return 0; }
    }

    private static String b(Boolean v) { return v == true ? 'true' : 'false'; }

    private static String xmlEsc(String s) {
        if (s == null) return '';
        return s.replace('&','&amp;').replace('<','&lt;')
                .replace('>','&gt;').replace('"','&quot;').replace('\'','&apos;');
    }

    private static Integer visRank(String v) {
        if (v == 'Visible')   return 2;
        if (v == 'Available') return 1;
        return 0;
    }

    private static List<String> buildCatLabels(Set<String> cats) {
        Map<String,String> lm = new Map<String,String>{
            'objectSettings'              => 'Object & Field Permissions',
            'apexClassAccess'             => 'Apex Class Access',
            'visualforcePageAccess'       => 'Visualforce Page Access',
            'assignedApps'                => 'Assigned Apps',
            'appPermissions'              => 'App Permissions',
            'assignedConnectedApps'       => 'Assigned Connected Apps',
            'flowAccess'                  => 'Flow Access',
            'namedCredentialAccess'       => 'Named Credential Access',
            'externalDataSourceAccess'    => 'External Data Source Access',
            'customPermissions'           => 'Custom Permissions',
            'customMetadataTypes'         => 'Custom Metadata Types',
            'customSettingDefinitions'    => 'Custom Setting Definitions',
            'servicePresenceStatusAccess' => 'Service Presence Status Access',
            'tabSettings'                 => 'Tab Settings',
            'serviceProviderAccess'       => 'Service Providers',
            'systemPermissions'           => 'System Permissions'
        };
        List<String> res = new List<String>();
        for (String c : cats) { if (lm.containsKey(c)) res.add(lm.get(c)); }
        return res;
    }
}

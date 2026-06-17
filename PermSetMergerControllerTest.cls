/**
 * @description Test coverage for PermSetMergerController.
 *
 *  The SOAP Metadata API calls (deploy + checkDeployStatus) are exercised
 *  through HttpCalloutMock so no real callout is made. The read side runs
 *  against the running user's own profile-backed PermissionSet, which always
 *  exists, so no special data setup is required for the source side.
 */
@isTest
private class PermSetMergerControllerTest {

    private static final String FAKE_SESSION = '00Dxx0000000000!FAKE_SESSION_ID';
    private static final String FAKE_JOB_ID  = '0Af000000000001AAA';

    // ─── Mocks ──────────────────────────────────────────────────────────────

    /** Returns a successful deploy id, then a Succeeded status. */
    private class SuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/xml');
            if (req.getBody().contains('<deploy ')) {
                res.setBody(
                    '<?xml version="1.0" encoding="UTF-8"?>'
                  + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
                  + '<soapenv:Body><deployResponse><result>'
                  + '<id>' + FAKE_JOB_ID + '</id></result></deployResponse>'
                  + '</soapenv:Body></soapenv:Envelope>');
            } else {
                res.setBody(
                    '<?xml version="1.0" encoding="UTF-8"?>'
                  + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
                  + '<soapenv:Body><checkDeployStatusResponse><result>'
                  + '<done>true</done><status>Succeeded</status>'
                  + '<numberComponentsDeployed>1</numberComponentsDeployed>'
                  + '<numberComponentsTotal>1</numberComponentsTotal>'
                  + '</result></checkDeployStatusResponse>'
                  + '</soapenv:Body></soapenv:Envelope>');
            }
            return res;
        }
    }

    /** Returns a SOAP fault for the deploy call (failure path). */
    private class FaultMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setHeader('Content-Type', 'text/xml');
            res.setBody(
                '<?xml version="1.0" encoding="UTF-8"?>'
              + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
              + '<soapenv:Body><soapenv:Fault>'
              + '<faultcode>sf:INVALID_SESSION_ID</faultcode>'
              + '<faultstring>INVALID_SESSION_ID: Invalid Session ID found</faultstring>'
              + '</soapenv:Fault></soapenv:Body></soapenv:Envelope>');
            return res;
        }
    }

    /** Returns a failed-but-done status for checkDeployStatus (component error path). */
    private class FailedStatusMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/xml');
            res.setBody(
                '<?xml version="1.0" encoding="UTF-8"?>'
              + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
              + '<soapenv:Body><checkDeployStatusResponse><result>'
              + '<done>true</done><status>Failed</status>'
              + '<numberComponentsDeployed>0</numberComponentsDeployed>'
              + '<numberComponentsTotal>1</numberComponentsTotal>'
              + '<details><componentFailures><problem>Something went wrong</problem>'
              + '</componentFailures></details>'
              + '</result></checkDeployStatusResponse>'
              + '</soapenv:Body></soapenv:Envelope>');
            return res;
        }
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private static Id anyProfileId() {
        return [SELECT Id FROM Profile ORDER BY Name LIMIT 1].Id;
    }

    /** A non-profile permission set to use as the merge target. */
    private static PermissionSet makeTargetPermSet() {
        PermissionSet ps = new PermissionSet(
            Name  = 'PSM_Test_Target',
            Label = 'PSM Test Target'
        );
        insert ps;
        return ps;
    }

    // ─── Picklist + summary reads ───────────────────────────────────────────────

    @isTest
    static void testPicklistsAndSummary() {
        Test.startTest();
        List<PermSetMergerController.PicklistOption> profiles = PermSetMergerController.getProfiles();
        List<PermSetMergerController.PicklistOption> psets    = PermSetMergerController.getPermissionSets();
        PermSetMergerController.PermSummary summary           = PermSetMergerController.getProfileSummary(anyProfileId());
        String session                                        = PermSetMergerController.getSessionId();
        Test.stopTest();

        System.assert(!profiles.isEmpty(), 'Org should always have profiles');
        System.assertNotEquals(null, psets,    'Permission set list should not be null');
        System.assertNotEquals(null, summary,  'Summary should not be null');
        System.assertNotEquals(null, session,  'Session id should not be null');
    }

    // ─── Merge happy path (deploy + poll Succeeded) ──────────────────────────────

    @isTest
    static void testMergeSuccessAndPoll() {
        PermissionSet target = makeTargetPermSet();
        Id profileId = anyProfileId();

        // Exercise every branch of buildPermSetXml by selecting all categories.
        List<String> allCats = new List<String>{
            'objectSettings','apexClassAccess','visualforcePageAccess','assignedApps',
            'appPermissions','assignedConnectedApps','flowAccess','namedCredentialAccess',
            'externalDataSourceAccess','customPermissions','customMetadataTypes',
            'customSettingDefinitions','servicePresenceStatusAccess','tabSettings',
            'serviceProviderAccess','systemPermissions'
        };

        Test.setMock(HttpCalloutMock.class, new SuccessMock());
        Test.startTest();
        PermSetMergerController.MergeResult result =
            PermSetMergerController.mergePermissions(profileId, target.Name, allCats, FAKE_SESSION);

        PermSetMergerController.DeployStatus status =
            PermSetMergerController.checkDeployStatus(result.jobId, FAKE_SESSION);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Merge should report success');
        System.assertEquals(FAKE_JOB_ID, result.jobId, 'Job id should come from the mocked response');
        System.assert(!result.merged.isEmpty(), 'Merged category labels should be populated');

        System.assertEquals(true, status.done, 'Status should be done');
        System.assertEquals('Succeeded', status.state, 'Status should be Succeeded');
        System.assertEquals(1, status.numberTotal, 'Total components parsed from response');
    }

    // ─── Merge with no session (guard) ───────────────────────────────────────────

    @isTest
    static void testMergeWithoutSession() {
        PermissionSet target = makeTargetPermSet();
        Test.startTest();
        PermSetMergerController.MergeResult result =
            PermSetMergerController.mergePermissions(
                anyProfileId(), target.Name, new List<String>{ 'systemPermissions' }, null);
        Test.stopTest();

        System.assertEquals(false, result.success, 'Blank session should fail fast');
    }

    // ─── Deploy SOAP fault path ──────────────────────────────────────────────────

    @isTest
    static void testMergeDeployFault() {
        PermissionSet target = makeTargetPermSet();
        Test.setMock(HttpCalloutMock.class, new FaultMock());

        Test.startTest();
        PermSetMergerController.MergeResult result =
            PermSetMergerController.mergePermissions(
                anyProfileId(), target.Name, new List<String>{ 'objectSettings' }, FAKE_SESSION);
        Test.stopTest();

        // soapDeploy throws AuraHandledException, caught and returned as failure
        System.assertEquals(false, result.success, 'SOAP fault should produce a failure result');
    }

    // ─── checkDeployStatus failed-component path ─────────────────────────────────

    @isTest
    static void testCheckDeployStatusFailed() {
        Test.setMock(HttpCalloutMock.class, new FailedStatusMock());
        Test.startTest();
        PermSetMergerController.DeployStatus status =
            PermSetMergerController.checkDeployStatus(FAKE_JOB_ID, FAKE_SESSION);
        Test.stopTest();

        System.assertEquals(true, status.done, 'Status should be done');
        System.assertEquals('Failed', status.state, 'Status should be Failed');
        System.assertNotEquals(null, status.errorMessage, 'Failure should surface a problem message');
    }
}

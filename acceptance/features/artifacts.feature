Feature: Artifacts

    Scenario: Create and use artifact from single file
        Given a source file "foobar.json":
            """
            {
                "foo": "bar"
            }
            """
        When artifact is created for file "foobar.json"
        And artifact is extracted for file "foobar.json"
        Then the restored file "foobar.json" should match its source

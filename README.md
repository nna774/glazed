# glazed: Modern oxidized

This is a successor of oxidized, a network device configuration scraper. Offers these advantages:

- __Cloud native.__ Glazed offers storing into cloud storage, and run in cloud environment such as AWS Lambda.
- __Secret aware.__ Glazed allows saving raw configuration, and commiting reducted configuration to git for wider visibility. Reducted configuration can be configured by: remove entirely, or HMAC sum.
- __Git flow.__ Glazed allows commiting raw configuration to a dedicated repo for complete history, and commiting reducted configuration to a team-central repo on a topic branch, and developers can open a pull request once they completes a change, to clearly explain what has changed, and why.
- __Building blocks.__ Glazed offers well organized components so everyone can pick some of them as a building block. For instance, retrieving configuration, persisting configuration.
- __Device manifest (dialect api).__ Glazed provides oxidized like DSL but much better in term of inheritance, reusability, and internal structure. We'd like to avoid evaluating logics within Dialect itself.
  - __Oxidized compatible layer.__ Read device manifests from oxidized gem in Ruby::Box to dynamically translate to Glazed native manifests. (Low priority)

Priority: Oxidized compatible layer is ignorable for now. Initial device targets: Cisco IOS, Cisco WLC, Juniper, NEC IX

"""Exercises architecture-gate syntax that cannot be compiled into the app target."""
from pathlib import Path
import tempfile
import unittest
if __package__:
    from .validate_local_persistence import validate
else:
    from validate_local_persistence import validate


class SchemaGateTests(unittest.TestCase):
    def failures(self, source):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Pawtrackr"
            app.mkdir()
            (app / "Example.swift").write_text(source)
            return validate(root)

    def test_staged_plan_cannot_hide_in_multiline_protocols(self):
        self.assertTrue(self.failures("enum Plan: OtherProtocol,\n SchemaMigrationPlan {}"))

    def test_migration_argument_whitespace_is_detected(self):
        self.assertTrue(self.failures("let value = Factory(migrationPlan \n : Plan.self)"))

    def test_unique_on_a_new_model_is_detected(self):
        self.assertTrue(self.failures("@Model class NewModel { @Attribute(\n .unique) var value = 0 }"))
        self.assertTrue(self.failures("@Model class NewModel { #Unique<NewModel>([\\.value]) }"))

    def test_comments_and_string_literals_do_not_trigger_schema_gate(self):
        self.assertFalse(self.failures('// SchemaMigrationPlan\nlet text = "migrationPlan: @Attribute(.unique)"'))

    def test_optional_additions_and_local_configuration_are_allowed(self):
        self.assertFalse(self.failures("@Model class Item { var amount: Decimal?\n }\nlet config = ModelConfiguration(cloudKitDatabase: .none)"))


if __name__ == "__main__":
    unittest.main()

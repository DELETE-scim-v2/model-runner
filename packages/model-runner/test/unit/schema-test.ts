import { expect } from 'chai'
import * as fs from 'fs'
import * as path from 'path'
import { RequestInput } from '@covid-modeling/api'
import { enforceInputSchema, enforceOutputSchema } from '../../src/schema'

suite('schema tests', () => {
  test('enforceInputSchema, on valid input', () => {
    const inputData = fs.readFileSync(
      path.join(path.parse(__dirname).dir, 'test-job-mrc-ide-covidsim.json'),
      'utf8'
    )
    const input = JSON.parse(inputData) as RequestInput
    expect(() => enforceInputSchema(input)).not.to.throw()
  })

  test('enforceInputSchema, on invalid input', () => {
    const input = JSON.parse('{}') as RequestInput
    expect(() => enforceInputSchema(input)).to.throw(
      Error,
      'Invalid model input JSON. Details:'
    )
  })

  test('enforceOutputSchema, on valid output', () => {
    expect(() =>
      enforceOutputSchema(path.join(__dirname, 'valid-output.json'))
    ).not.to.throw()
  })

  test('enforceOutputSchema, on invalid output', () => {
    expect(() =>
      enforceOutputSchema(path.join(__dirname, 'bad-output-schema.json'))
    ).to.throw(Error, 'Invalid model output JSON. Details:')
  })
})

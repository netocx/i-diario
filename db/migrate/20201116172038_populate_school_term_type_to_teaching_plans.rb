class PopulateSchoolTermTypeToTeachingPlans < ActiveRecord::Migration
  def change
    TeachingPlan.where.not(school_term: '').each do |teaching_plan|
      school_term = teaching_plan.school_term

      if school_term.ends_with?('bimester')
        steps_number = 4
        step_number = case school_term
                      when 'first_bimester' then 1
                      when 'second_bimester' then 2
                      when 'third_bimester' then 3
                      else 4
                      end
      elsif school_term.ends_with?('eja') || school_term.ends_with?('semester')
        steps_number = 2
        step_number = case school_term
                      when 'first_bimester_eja' then 1
                      when 'first_semester' then 1
                      when 'second_bimester_eja' then 2
                      else 2
                      end
      else
        steps_number = 3
        step_number = case school_term
                      when 'first_trimester' then 1
                      when 'second_trimester' then 2
                      else 3
                      end
      end

      next unless (school_term_type = SchoolTermType.find_by(steps_number: steps_number))

      school_term_type_step_id = SchoolTermTypeStep.find_by(
        school_term_type_id: school_term_type.id,
        step_number: step_number
      )&.id

      next if school_term_type_step_id.blank?

      teaching_plan.update(
        school_term_type_id: school_term_type.id,
        school_term_type_step_id: school_term_type_step_id
      )
    end
  end
end
